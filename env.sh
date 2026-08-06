#!/usr/bin/env bash
# Shared configuration. Sourced by every script here — not meant to be run.
#
# Run the scripts with bash, not fish: the install commands use heredocs and
# process substitution throughout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="${SCRIPT_DIR}/.secrets"

# ---------------------------------------------------------------- AWS / cluster

export AWS_REGION="us-east-1"
export CLUSTER_NAME="amp-test"
export K8S_VERSION="1.34"
export CILIUM_VERSION="1.19.6"

# ------------------------------------------------------------------------- RDS

export DB_INSTANCE_ID="${CLUSTER_NAME}-pg"
export DB_ENGINE_VERSION="17.10"
export DB_INSTANCE_CLASS="db.t4g.small"
export DB_STORAGE_GB="50"
export DB_MASTER_USER="postgres"

# Agent Manager's own database, and the three Thunder keeps.
export AMP_DB_NAME="agentmanager"
export AMP_DB_USER="agentmanager"
export THUNDER_DB_USER="thunder"
export THUNDER_DBS="configdb runtimedb userdb"

# ------------------------------------------------------- Agent Manager release

# Must be a tag that exists BOTH as a GHCR chart tag and as a git tag named
# amp/v${VERSION} — the install pulls values files from raw.githubusercontent at
# that tag. The literal "0.0.0-dev" in the docs is a local-build placeholder and
# is published under neither.
export VERSION="0.0.0-dev-20260806"
export HELM_CHART_REGISTRY="ghcr.io/wso2"

# ---------------------------------------------------------------- Hostnames

# Written by ./00-domain.sh once the Route 53 zone exists. Every management
# surface is a single label under BASE_DOMAIN, because cert-manager issues a
# single-level wildcard for it.
if [[ -f "${SCRIPT_DIR}/domain.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/domain.env"
else
  export BASE_DOMAIN="__SET_ME__"
  export ROUTE53_ZONE_ID="__SET_ME__"
fi

export ACME_EMAIL="jhivan@wso2.com"

# Production, because the install depends on the certificates being publicly
# trusted: env-Thunder provisioning runs with SKIP_CA_BUNDLE_TRUST=true, and a
# staging certificate would fail that call's TLS verification. The rate limit
# that bites is 5 *duplicate* certs per week; the four issued here are all
# distinct names. Swap in the staging directory only for a dry run.
export ACME_SERVER="https://acme-v02.api.letsencrypt.org/directory"

# ------------------------------------------------------------------ Namespaces

export AMP_NS="wso2-amp"
export THUNDER_NS="amp-thunder"
export DEFAULT_NS="default"
export CONTROL_PLANE_NS="openchoreo-control-plane"
export DATA_PLANE_NS="openchoreo-data-plane"
export BUILD_CI_NS="openchoreo-workflow-plane"
export OBSERVABILITY_NS="openchoreo-observability-plane"

# ------------------------------------------------------- Derived public names

export CONSOLE_PUBLIC_HOST="console.${BASE_DOMAIN}"
export API_PUBLIC_HOST="api-amp.${BASE_DOMAIN}"
export THUNDER_PUBLIC_HOST="thunder.${BASE_DOMAIN}"
export CP_GW_PUBLIC_HOST="cp.${BASE_DOMAIN}"
export OBS_API_PUBLIC_HOST="traces.${BASE_DOMAIN}"
export AGENTS_DOMAIN="agents.${BASE_DOMAIN}"

export CONSOLE_PUBLIC_URL="https://${CONSOLE_PUBLIC_HOST}"
export API_PUBLIC_URL="https://${API_PUBLIC_HOST}"
export THUNDER_PUBLIC_URL="https://${THUNDER_PUBLIC_HOST}"
export OBS_API_PUBLIC_URL="https://${OBS_API_PUBLIC_HOST}"

export THUNDER_INTERNAL_URL="http://amp-thunder-extension-service.${THUNDER_NS}.svc.cluster.local:8090"
export OPENCHOREO_API_URL="http://openchoreo-api.${CONTROL_PLANE_NS}.svc.cluster.local:8080"

# Agents inside the cluster export traces over the data-plane gateway's /otel
# route. Publish otel.${BASE_DOMAIN} if agents outside the cluster need it.
export INSTRUMENTATION_URL="http://default-default.gateway.localhost:19080/otel"

# Container registry that build workflows push agent images to, created by
# ./025-registry.sh.
#
# Not ECR: the publish-image workflow template pushes ${workflowRunName}-image,
# a different repository name on every single build, and ECR has no
# push-to-create. It also mounts a static .dockerconfigjson, so it would never
# refresh ECR's 12-hour token. A distribution registry auto-creates on push.
export REGISTRY_NS="registry"
export REGISTRY_HOST="registry.${BASE_DOMAIN}"
export REGISTRY_ENDPOINT="${REGISTRY_HOST}"

# The docs' production value is 100Gi. Lowered for an evaluation cluster; this
# single OpenSearch node holds every trace, log and metric.
export OPENSEARCH_PV_SIZE="${OPENSEARCH_PV_SIZE:-50Gi}"

# ------------------------------------------------- Generated platform secrets

# Generated once and reused forever. Thunder seeds these into its database on
# first boot and helm upgrade never re-seeds, so regenerating them on a re-run
# would silently desynchronise Thunder from every consumer. Guard the file.
generate_platform_secrets() {
  local f="${SECRETS_DIR}/platform-secrets.env"
  [[ -f "$f" ]] && return 0

  mkdir -p "${SECRETS_DIR}"
  chmod 700 "${SECRETS_DIR}"
  umask 077
  cat > "$f" <<EOF
export AMP_API_CLIENT_SECRET="$(openssl rand -hex 32)"
export AMP_SYSTEM_CLIENT_SECRET="$(openssl rand -hex 32)"
export AMP_PUBLISHER_CLIENT_SECRET="$(openssl rand -hex 32)"
export AM_OBSERVER_CLIENT_SECRET="$(openssl rand -hex 32)"
export WORKFLOW_PUBLISHER_SECRET="$(openssl rand -hex 32)"
export OBSERVER_READER_SECRET="$(openssl rand -hex 32)"
export OPENSEARCH_USERNAME="admin"
export OPENSEARCH_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)Aa1!"
export AMP_DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=@" ' | head -c 28)"
export THUNDER_DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=@" ' | head -c 28)"
export DB_MASTER_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=@" ' | head -c 28)"
EOF
  chmod 600 "$f"
  echo "Generated platform secrets at $f — back these up now." >&2
}

generate_platform_secrets
# shellcheck source=/dev/null
source "${SECRETS_DIR}/platform-secrets.env"

# ----------------------------------------------------------------- Helpers

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

require_placeholders_filled() {
  local missing=()
  for v in VERSION BASE_DOMAIN ROUTE53_ZONE_ID; do
    if [[ "${!v}" == "__SET_ME__" ]]; then missing+=("$v"); fi
  done
  if (( ${#missing[@]} )); then die "Fill these in env.sh first: ${missing[*]}"; fi
  # Explicit success: under set -e, a function whose last statement is a false
  # `(( )) && die` returns 1 and silently kills the calling script.
  return 0
}

# Client-credentials token from platform Thunder for the Agent Manager API.
# Thunder only grants scopes that are explicitly requested, so callers must
# pass everything they need (e.g. "amp:gateway:read amp:gateway:delete").
am_token() {
  local scopes="$1" token
  token="$(curl -sf -X POST "${THUNDER_PUBLIC_URL}/oauth2/token" \
    -u "amp-api-client:${AMP_API_CLIENT_SECRET}" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "scope=${scopes}" | jq -r '.access_token // empty')"
  [[ -n "$token" ]] || die "could not obtain an Agent Manager token from ${THUNDER_PUBLIC_URL}"
  echo "$token"
}

# Upserts one Route 53 record. EKS gateways return ELB hostnames, so these are
# CNAMEs — except a zone apex, which cannot be a CNAME.
upsert_dns() {
  local name="$1" target="$2" type="${3:-CNAME}"
  aws route53 change-resource-record-sets \
    --hosted-zone-id "${ROUTE53_ZONE_ID}" \
    --change-batch "$(jq -n \
        --arg n "$name" --arg t "$target" --arg ty "$type" \
        '{Changes:[{Action:"UPSERT",ResourceRecordSet:{
            Name:$n, Type:$ty, TTL:60,
            ResourceRecords:[{Value:$t}]}}]}')" \
    --output text --query 'ChangeInfo.Status'
}

# Reads a plane gateway's LoadBalancer address, waiting for it to be assigned.
gateway_address() {
  local ns="$1"
  for _ in $(seq 1 60); do
    local addr
    addr="$(kubectl get svc gateway-default -n "$ns" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$addr" ]] && { echo "$addr"; return 0; }
    sleep 10
  done
  die "gateway-default in $ns never got a LoadBalancer address"
}

kubeconfig_points_at_cluster() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ "$ctx" == *"${CLUSTER_NAME}"* ]] \
    || die "kubectl context is '${ctx}', which is not ${CLUSTER_NAME}. Run: aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}"
}
