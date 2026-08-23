#!/usr/bin/env bash
# Adds a new environment with split INGRESS/EGRESS gateways.
#
#   ./07-add-environment.sh <env-name> "<Display Name>" [--production]
#
# This replaces the product's deployments/scripts/add-environment.sh, which
# hardcodes gateway vhosts to http://<env>-<org>.gateway.localhost:19080 with
# no override — and vhosts are frozen at first registration, so on a TLS
# install with real domains the gateway must be installed with the right vhost
# the first time. The environment-creation payload, per-env Thunder step and
# split-gateway layout below mirror that script; only the vhosts/hostnames
# (and the namespace secrets the chart expects on this install) differ. It
# also wires the new environment into the default deployment pipeline as a
# promotion target of 'default' — the product script leaves the pipeline
# untouched, which strands the environment outside every promotion flow.
#
# Environments are provision-once: gateway role, vhost and hostname freeze at
# first registration, and a gateway that has ever held deployment records —
# even UNDEPLOYED/ARCHIVED ones — cannot be deregistered. Get the topology
# right here; there is no reshape-in-place.
#
# Env name limit: the APIGateway controller materializes a Service named
# api-platform-<org>-<env>-egress-gw-gateway-gateway-runtime, which must fit
# Kubernetes' 63-char limit — for org "default" in split topology that caps
# the env name at 8 characters ("production" is too long; use "prod").

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

require_placeholders_filled
kubeconfig_points_at_cluster

ENV_NAME="${1:-}"
DISPLAY_NAME="${2:-}"
IS_PRODUCTION=false
[[ "${3:-}" == "--production" ]] && IS_PRODUCTION=true

[[ -n "${ENV_NAME}" && -n "${DISPLAY_NAME}" ]] \
  || die "usage: $0 <env-name> \"<Display Name>\" [--production]"
[[ "${ENV_NAME}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
  || die "env name must be lowercase alphanumeric with hyphens"
(( ${#ENV_NAME} <= 8 )) \
  || die "env name '${ENV_NAME}' is ${#ENV_NAME} chars; max 8 for org 'default' in split topology"

ORG=default
INGRESS_NS="${ORG}-${ENV_NAME}"
EGRESS_NS="${ORG}-${ENV_NAME}-egress"
INGRESS_RELEASE="api-platform-${ORG}-${ENV_NAME}"
EGRESS_RELEASE="api-platform-${ORG}-${ENV_NAME}-egress"
INGRESS_HOST="${ENV_NAME}-${ORG}.${AGENTS_DOMAIN}"
EGRESS_HOST="${ENV_NAME}-${ORG}-egress.${AGENTS_DOMAIN}"

ENV_THUNDER_RELEASE="amp-thunder-${ORG}-${ENV_NAME}"
# env-Thunder hostnames are handle-based: <handle>.${BASE_DOMAIN}. The handle is
# generated once per (org, env) and reused forever, because Thunder's issuer is
# minted from it and is immutable afterwards — a second handle for the same
# environment reads as a different, unprovisioned one.
ENV_HANDLE="$(env_thunder_handle "${ORG}" "${ENV_NAME}")"
ENV_THUNDER_ISSUER="https://${ENV_HANDLE}.${BASE_DOMAIN}"
ENV_THUNDER_JWKS="http://${ENV_THUNDER_RELEASE}-service.${ENV_THUNDER_RELEASE}.svc.cluster.local:8090/oauth2/jwks"
AM_JWKS="http://amp-api.${AMP_NS}.svc.cluster.local:9000/auth/external/jwks.json"

CHART="oci://${HELM_CHART_REGISTRY}/wso2-amp-api-platform-gateway-extension"
RAW_BASE="https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}"

# ============================================================ Environment

log "Creating environment '${ENV_NAME}' (production=${IS_PRODUCTION})"
TOKEN="$(am_token "amp:environment:create amp:environment:read amp:gateway:create amp:gateway:read")"

# The https listener variant must be present on a TLS install: the Environment's
# external gateway wholly replaces the data plane's, and the console builds the
# deployed-agent invoke URL from the https variant — without it the URL is empty.
code="$(curl -s -o /tmp/env-create-body -w '%{http_code}' -X POST \
  "${API_PUBLIC_URL}/api/v1/orgs/${ORG}/environments" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg n "${ENV_NAME}" --arg d "${DISPLAY_NAME}" \
        --arg h "${AGENTS_DOMAIN}" --argjson prod "${IS_PRODUCTION}" '{
    name: $n, displayName: $d, dataplaneRef: "default", dnsPrefix: $n,
    isProduction: $prod,
    gateway: {ingress: {external: {
      http:  {host: $h, port: 80},
      https: {host: $h, port: 443}
    }}}}')")"
case "$code" in
  201) echo "  environment created" ;;
  409) echo "  environment already exists, continuing" ;;
  *)   die "environment create returned HTTP ${code}: $(cat /tmp/env-create-body)" ;;
esac

# ============================================================ env-Thunder

log "Provisioning env-Thunder for '${ENV_NAME}' at ${ENV_HANDLE}.${BASE_DOMAIN}"
SCRIPT="${SECRETS_DIR}/add-environment-thunder.sh"
curl -fsSL "${RAW_BASE}/deployments/scripts/add-environment-thunder.sh" -o "${SCRIPT}"

# THUNDER_HANDLE is passed explicitly rather than letting the script generate
# one: it registers the handle with agent-manager-service before touching the
# cluster, and that PUT upserts for the same (org, env), so a re-run resolves to
# the same host and issuer instead of minting a second, unrecorded handle.
ENV_NAME="${ENV_NAME}" \
DISPLAY_NAME="${DISPLAY_NAME}" \
ORG_NAME="${ORG}" \
WAIT_TIMEOUT=300s \
AMP_API_URL="${API_PUBLIC_URL}/api/v1" \
IDP_TOKEN_URL="${THUNDER_PUBLIC_URL}/oauth2/token" \
IDP_CLIENT_ID=amp-api-client \
IDP_CLIENT_SECRET="${AMP_API_CLIENT_SECRET}" \
PLATFORM_THUNDER_ISSUER="${THUNDER_PUBLIC_URL}" \
PLATFORM_THUNDER_JWKS_URL="${THUNDER_PUBLIC_URL}/oauth2/jwks" \
THUNDER_HOST_BASE_DOMAIN="${BASE_DOMAIN}" \
THUNDER_HANDLE="${ENV_HANDLE}" \
TLS_ENABLED=true \
SKIP_CA_BUNDLE_TRUST=true \
bash "${SCRIPT}"

log "env-Thunder console admin password for '${ENV_NAME}'"
kubectl get secret "${ENV_THUNDER_RELEASE}-admin-credentials" \
  -n "${ENV_THUNDER_RELEASE}" -o jsonpath='{.data.password}' | base64 -d \
  | tee "${SECRETS_DIR}/env-thunder-${ENV_NAME}-admin-password.txt"
echo
chmod 600 "${SECRETS_DIR}/env-thunder-${ENV_NAME}-admin-password.txt"

# ============================================================ Gateway namespaces

log "Preparing gateway namespaces ${INGRESS_NS} and ${EGRESS_NS}"
for ns in "${INGRESS_NS}" "${EGRESS_NS}"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  # The sandbox NetworkPolicy allows agent egress on port 22893 only to
  # namespaces carrying this label; it is stamped by scripts, never the chart.
  kubectl label namespace "$ns" "amp.wso2.com/api-platform-gateway=true" --overwrite

  # gateway-controller 1.2.0-beta needs its AES-256 key from a Secret in the
  # release's own namespace.
  if ! kubectl get secret gateway-encryption-keys -n "$ns" >/dev/null 2>&1; then
    keyfile="${SECRETS_DIR}/gateway-aesgcm-${ns}.key"
    umask 077
    openssl rand 32 > "${keyfile}"
    kubectl create secret generic gateway-encryption-keys \
      --namespace "$ns" \
      --from-file=default-aesgcm256-v1.bin="${keyfile}"
    warn "Gateway encryption key for ${ns} kept at ${keyfile} — it encrypts stored gateway credentials."
  fi

  # The bootstrap job reads its IDP client credentials from this secret; the
  # chart's inline default is the shipped placeholder, which this install
  # replaced everywhere.
  kubectl create secret generic gateway-idp-credentials \
    --namespace "$ns" \
    --from-literal=client-id=amp-api-client \
    --from-literal=client-secret="${AMP_API_CLIENT_SECRET}" \
    --dry-run=client -o yaml | kubectl apply -f -
done

# ============================================================ Gateways

# Key managers and identity providers restated in full on both halves: helm
# --set on an indexed array replaces the whole list, and dropping
# keymanagers[0] silently breaks API-key authentication.
SHARED_ARGS=(
  --set agentManager.orgName="${ORG}"
  --set gateway.environment="${ENV_NAME}"
  --set developmentMode=false
  --set agentManager.idp.existingSecret=gateway-idp-credentials
  --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].name=agent-manager-service"
  --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].issuer=agent-manager-service"
  --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].jwks.remote.uri=${AM_JWKS}"
  --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].jwks.remote.skipTlsVerify=true"
  --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].name=ThunderKeyManager"
  --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].issuer=${ENV_THUNDER_ISSUER}"
  --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].jwks.remote.uri=${ENV_THUNDER_JWKS}"
  --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].jwks.remote.skipTlsVerify=false"
  --set "bootstrap.identityProviders[0].name=ThunderKeyManager"
  --set "bootstrap.identityProviders[0].issuer=${ENV_THUNDER_ISSUER}"
  --set "bootstrap.identityProviders[0].jwksUri=${ENV_THUNDER_JWKS}"
  --set "bootstrap.identityProviders[0].skipTlsVerify=false"
)

log "Installing the INGRESS gateway for '${ENV_NAME}'"
helm upgrade --install --server-side=false "${INGRESS_RELEASE}" "${CHART}" \
  --version "${VERSION}" \
  --namespace "${INGRESS_NS}" \
  --set apiGateway.namespace="${INGRESS_NS}" \
  --set gateway.type=INGRESS \
  --set gateway.displayName="${DISPLAY_NAME} API Platform Gateway" \
  --set gateway.vhost="https://${INGRESS_HOST}" \
  --set gateway.hostname="${INGRESS_HOST}" \
  "${SHARED_ARGS[@]}" \
  --timeout 900s

log "Installing the EGRESS gateway for '${ENV_NAME}'"
# gateway.name and gateway.hostname must be set explicitly: the chart defaults
# carry no discriminator, so the egress release would otherwise register the
# same gateway name and claim the same hostname as the ingress half.
helm upgrade --install --server-side=false "${EGRESS_RELEASE}" "${CHART}" \
  --version "${VERSION}" \
  --namespace "${EGRESS_NS}" \
  --set apiGateway.namespace="${EGRESS_NS}" \
  --set gateway.type=EGRESS \
  --set gateway.name="${EGRESS_RELEASE}" \
  --set gateway.displayName="${DISPLAY_NAME} API Platform Gateway (Egress)" \
  --set gateway.vhost="https://${EGRESS_HOST}" \
  --set gateway.hostname="${EGRESS_HOST}" \
  "${SHARED_ARGS[@]}" \
  --timeout 900s

kubectl wait --for=condition=Programmed "apigateway/${INGRESS_RELEASE}" \
  -n "${INGRESS_NS}" --timeout=300s
kubectl wait --for=condition=Programmed "apigateway/${EGRESS_RELEASE}" \
  -n "${EGRESS_NS}" --timeout=300s

# ============================================================ Deployment pipeline

log "Adding '${ENV_NAME}' to the default deployment pipeline"
# The DeploymentPipeline CR is Helm-owned by amp-platform-resources, so a
# kubectl patch would be reverted by the next chart upgrade. Restate it through
# the chart's deploymentPipeline.promotionOrder value instead, merging this env
# into the existing targets; --reuse-values keeps everything else intact.
CURRENT_TARGETS="$(kubectl get deploymentpipeline default -n "${DEFAULT_NS}" \
  -o jsonpath='{.spec.promotionPaths[0].targetEnvironmentRefs[*].name}' 2>/dev/null || true)"
jq -n --arg new "${ENV_NAME}" --arg cur "${CURRENT_TARGETS}" '{
  deploymentPipeline: {promotionOrder: [{
    sourceEnvironmentRef: {name: "default"},
    targetEnvironmentRefs:
      (($cur | split(" ") | map(select(length > 0))) + [$new] | unique | map({name: .}))
  }]}}' > "${SECRETS_DIR}/pipeline-values.json"
helm upgrade amp-platform-resources \
  "oci://${HELM_CHART_REGISTRY}/wso2-amp-platform-resources-extension" \
  --version "${VERSION}" \
  --namespace "${DEFAULT_NS}" \
  --reuse-values \
  -f "${SECRETS_DIR}/pipeline-values.json" \
  --timeout 600s

# ============================================================ Verify

log "Verification"
curl -sf -H "Authorization: Bearer ${TOKEN}" "${API_PUBLIC_URL}/api/v1/orgs/${ORG}/gateways" \
  | jq -r --arg e "${ENV_NAME}" \
    '.gateways[] | select([.environments[].name] | index($e)) | "\(.name)\t\(.gatewayType)\t\(.status)\t\(.vhost)"'
kubectl get deploymentpipeline default -n "${DEFAULT_NS}" \
  -o jsonpath='promotion paths: {.spec.promotionPaths}{"\n"}'
kubectl get pods -n "${INGRESS_NS}"
kubectl get pods -n "${EGRESS_NS}"

cat <<SUMMARY

Environment '${ENV_NAME}' ready.
  Ingress gateway   https://${INGRESS_HOST}   (ns ${INGRESS_NS})
  Egress gateway    ${EGRESS_HOST}            (ns ${EGRESS_NS}, reached in-cluster via its runtime URL)
  env-Thunder       ${ENV_THUNDER_ISSUER}     (admin password in ${SECRETS_DIR}/env-thunder-${ENV_NAME}-admin-password.txt)
  Pipeline          default -> ${ENV_NAME} promotion path added

Both gateway hostnames are covered by the existing *.${AGENTS_DOMAIN} DNS record
and certificate, and ${ENV_HANDLE}.${BASE_DOMAIN} by the *.${BASE_DOMAIN} record
and certificate 03 publishes — env-Thunder handles sit directly under the base
domain, so nothing new has to be issued or published for an added environment.
SUMMARY
