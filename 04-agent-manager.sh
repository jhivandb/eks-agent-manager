#!/usr/bin/env bash
# Phase 2 of the agent-manager guide: the Agent Manager itself.
#
# Follows _partials/_amp-installation.mdx (production variants) plus the
# "Wire the Remaining Public Endpoints", env-Thunder provisioning and gateway
# key-manager steps from on-your-environment.mdx.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

require_placeholders_filled
kubeconfig_points_at_cluster
source "${SECRETS_DIR}/db-endpoint.env"

CHART_BASE="oci://${HELM_CHART_REGISTRY}"
RAW_BASE="https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}"

# ------------------------------------------------- default environment gateway
#
# The default environment gets SPLIT INGRESS/EGRESS gateways — the same topology
# 07-add-environment.sh provisions for every other environment — rather than the
# guide's single BOTH-role gateway. Role, vhost and hostname are written into
# Agent Manager at FIRST registration and are immutable afterwards, and a gateway
# that has ever held deployment records cannot be deregistered (TROUBLESHOOTING
# §15), so this is decided here or never.
#
# Both halves live in their own namespaces and reach the data plane's kgateway
# (chart defaults kgateway.name/namespace to gateway-default/openchoreo-data-plane)
# via an HTTPRoute plus a ReferenceGrant the chart emits whenever
# apiGateway.namespace differs from kgateway.namespace. Both hostnames therefore
# resolve through the existing *.${AGENTS_DOMAIN} record and certificate — no new
# DNS, no new load balancer.
GW_ORG=default
GW_ENV=default
INGRESS_NS="${GW_ORG}-${GW_ENV}"
EGRESS_NS="${GW_ORG}-${GW_ENV}-egress"
INGRESS_RELEASE="api-platform-${GW_ORG}-${GW_ENV}"
EGRESS_RELEASE="api-platform-${GW_ORG}-${GW_ENV}-egress"
INGRESS_HOST="${GW_ENV}-${GW_ORG}.${AGENTS_DOMAIN}"
EGRESS_HOST="${GW_ENV}-${GW_ORG}-egress.${AGENTS_DOMAIN}"

# The egress half materializes a Service named
# api-platform-default-default-egress-gw-gateway-gateway-runtime — 62 characters,
# one under Kubernetes' 63-char limit. Nothing about these names has slack.
prepare_gateway_namespace() {
  local ns="$1"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  # The sandbox NetworkPolicy allows agent egress on port 22893 only to
  # namespaces carrying this label; it is stamped by scripts, never the chart.
  # 99-teardown.sh also discovers gateway namespaces by it.
  kubectl label namespace "$ns" "amp.wso2.com/api-platform-gateway=true" --overwrite

  # gateway-controller 1.2.0-beta reads its AES-256 key from a Secret in the
  # release's own namespace, so each half needs its own.
  if ! kubectl get secret gateway-encryption-keys -n "$ns" >/dev/null 2>&1; then
    local keyfile="${SECRETS_DIR}/gateway-aesgcm-${ns}.key"
    umask 077
    openssl rand 32 > "${keyfile}"
    kubectl create secret generic gateway-encryption-keys \
      --namespace "$ns" \
      --from-file=default-aesgcm256-v1.bin="${keyfile}"
    warn "Gateway encryption key for ${ns} kept at ${keyfile} — it encrypts stored gateway credentials."
  fi

  # The bootstrap job reads its IDP client credentials from this secret; the
  # chart's inline default is the shipped placeholder.
  kubectl create secret generic gateway-idp-credentials \
    --namespace "$ns" \
    --from-literal=client-id=amp-api-client \
    --from-literal=client-secret="${AMP_API_CLIENT_SECRET}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# ============================================================ Core: gateway operator

log "Step 1: gateway encryption key"
kubectl create namespace "${DATA_PLANE_NS}" --dry-run=client -o yaml | kubectl apply -f -
# The Secret key name is fixed: the controller looks for
# /app/data/aesgcm-keys/default-aesgcm256-v1.bin and crash-loops without it.
if ! kubectl get secret gateway-encryption-keys -n "${DATA_PLANE_NS}" >/dev/null 2>&1; then
  keyfile="${SECRETS_DIR}/gateway-aesgcm.key"
  umask 077
  openssl rand 32 > "${keyfile}"
  kubectl create secret generic gateway-encryption-keys \
    --namespace "${DATA_PLANE_NS}" \
    --from-file=default-aesgcm256-v1.bin="${keyfile}"
  warn "Gateway encryption key kept at ${keyfile}. It encrypts stored gateway"
  warn "credentials — lose it and those entries cannot be decrypted."
fi

log "Step 1: gateway operator ${GATEWAY_OPERATOR_VERSION}"
# Same crds/ trap as the control plane (§23): helm upgrade never touches them.
helm show crds oci://ghcr.io/wso2/api-platform/helm-charts/gateway-operator \
  --version "${GATEWAY_OPERATOR_VERSION}" \
  | kubectl apply --server-side --force-conflicts -f - >/dev/null

# gateway.helm.chartVersion is the *runtime* chart the operator deploys, and it
# does not follow the operator's own version — leaving it unset picks a default
# whose templates predate the controller reading its control-plane address from
# config, giving a gateway that serves traffic but never registers with Agent
# Manager. It cannot simply be pinned high either: 1.2.0-beta under operator
# 0.11.0 emits liveness/readiness probes carrying two handler types, which the
# API server rejects outright (§24). The images and probe handlers below are
# pinned for the same reason — this whole block mirrors upstream's
# deployments/setup/ensure-gateway-operator.sh at the matching tag, which is the
# only combination this release is tested against.
helm upgrade --install --server-side=false gateway-operator \
  oci://ghcr.io/wso2/api-platform/helm-charts/gateway-operator \
  --version "${GATEWAY_OPERATOR_VERSION}" \
  --namespace "${DATA_PLANE_NS}" \
  --set logging.level=info \
  --set gatewayApi.installStandardCRDs=false \
  --set "gateway.helm.chartVersion=${GATEWAY_CHART_VERSION}" \
  --set "gateway.values.gateway.controller.image.tag=${GATEWAY_IMAGE_VERSION}" \
  --set gateway.values.gateway.controller.image.repository=ghcr.io/wso2/api-platform/gateway-controller \
  --set "gateway.values.gateway.gatewayRuntime.image.tag=${GATEWAY_IMAGE_VERSION}" \
  --set gateway.values.gateway.gatewayRuntime.image.repository=ghcr.io/wso2/api-platform/gateway-runtime \
  --set gateway.values.gateway.controller.encryptionKeys.enabled=true \
  --set gateway.values.gateway.controller.encryptionKeys.secretName=gateway-encryption-keys \
  --set gateway.values.gateway.controller.deployment.livenessProbe.httpGet.path=/api/admin/v1/health \
  --set gateway.values.gateway.controller.deployment.livenessProbe.httpGet.port=admin \
  --set gateway.values.gateway.controller.deployment.readinessProbe.httpGet.path=/api/admin/v1/health \
  --set gateway.values.gateway.controller.deployment.readinessProbe.httpGet.port=admin \
  --timeout 600s

kubectl wait --for=condition=Available \
  deployment -l app.kubernetes.io/name=gateway-operator \
  -n "${DATA_PLANE_NS}" --timeout=300s

log "Step 1: RBAC for the data-plane cluster-agent"
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: wso2-api-platform-gateway-module
rules:
  - apiGroups: ["gateway.api-platform.wso2.com"]
    resources: ["restapis", "apigateways"]
    verbs: ["*"]
  - apiGroups: ["gateway.kgateway.dev"]
    resources: ["backends"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: wso2-api-platform-gateway-module
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: wso2-api-platform-gateway-module
subjects:
  - kind: ServiceAccount
    name: cluster-agent-dataplane
    namespace: ${DATA_PLANE_NS}
EOF

# ============================================================ Core: Agent Manager

log "Step 2: Agent Manager on external PostgreSQL"
# tlsEnabled=true is what makes the API publish https:// agent invoke URLs; left
# false the console publishes http:// and the browser blocks it as mixed content.
#
# amp-api runs a SINGLE replica. rc1 added gatewayManifestCache and defaults it
# to an in-process `memory` cache, documented as safe only at one replica: each
# replica observes only the manifest pushes routed to it, so two of them end up
# disagreeing about which policies the gateways report.
#
# All three autoscaling values are needed to hold that. The chart ships
# autoscaling.enabled=true with maxReplicas 10 at 80% CPU, so replicaCount alone
# is advisory — the HPA owns the replica count from the moment it exists, and
# minReplicas=1 only sets the floor. Disabling it is what actually pins amp-api
# at one; without that, a CPU spike scales straight into the configuration the
# memory cache is unsafe under. console.replicaCount stays 2, and so does the
# observer's below — neither holds shared state, and the console's own
# autoscaling ships disabled.
# --reuse-values so a re-run keeps values that later steps layer onto this
# release (the gatewayMgmt hostnames wired at the end of this script) instead
# of dropping them until that step re-applies them. No-op on first install.
#
# The six *.localhost chart defaults below are k3d-only and MUST be overridden;
# upstream's setup-platform.sh never touches them because its whole flow is
# local. None of them fail the install — they fail later, at runtime:
#
#   thunder.baseURL       Not just an address: agent-manager derives the RFC 8707
#                         `resource` parameter from it (client.go's
#                         SystemResourceIdentifier) for every Thunder admin-API
#                         token. Thunder registers its System resource server
#                         under the PUBLIC url, so any other value returns
#                         invalid_target and every identity call — user profile,
#                         agent-identity roles — 500s while both pods stay Ready
#                         and every health endpoint returns 200 (§25).
#   thunder.resolveToHost Emptied on purpose. It exists so a *.localhost baseURL
#                         can still be dialled in-cluster, but it only swaps the
#                         dial address — the scheme still comes from baseURL, and
#                         port 8090 is plain HTTP, so https:// against it fails
#                         the connection outright. Our public name resolves from
#                         inside the pod anyway (NAT hairpin, see README).
#   thunderHostBaseDomain The base every env-Thunder host hangs off. rc1 builds
#                         "<handle>.<domain>" from the handle registered for the
#                         environment; the old "<org>-<env>.thunder.<domain>"
#                         shape is gone. Left at amp.localhost this API reports
#                         env-Thunder endpoints that do not exist.
#   agents/gatewayBaseDomain  Added environments resolve nowhere without these.
#   agentsHttpPort        Must match environment.gateway.http.port set on the
#                         platform-resources chart at the end of this script;
#                         19080 is the k3d port mapping.
#
# Three more that rc1's guide adds: agentsHttpsPort is the https half of that
# same pair, and the console needs its own copy of thunderHostBaseDomain and
# tlsEnabled to build env-Thunder sign-in URLs. The console's tlsEnabled is
# --set-string deliberately — the chart declares that one as a quoted string
# ("false") while agentManagerService.config.tlsEnabled is a real bool, so plain
# --set would write a bool into a string field. The guide uses --set for both.
helm upgrade --install --server-side=false amp \
  "${CHART_BASE}/wso2-agent-manager" \
  --version "${VERSION}" \
  --namespace "${AMP_NS}" \
  --create-namespace \
  --reuse-values \
  --set console.config.instrumentationUrl="${INSTRUMENTATION_URL}" \
  --set console.config.auth.baseUrl="${THUNDER_PUBLIC_URL}" \
  --set console.config.auth.signInRedirectURL="${CONSOLE_PUBLIC_URL}/login" \
  --set console.config.auth.signOutRedirectURL="${CONSOLE_PUBLIC_URL}/login" \
  --set console.config.apiBaseUrl="${API_PUBLIC_URL}" \
  --set console.config.thunderHostBaseDomain="${BASE_DOMAIN}" \
  --set-string console.config.tlsEnabled=true \
  --set agentManagerService.config.amObserverPublicURL="${OBS_API_PUBLIC_URL}" \
  --set console.ocIngress.hostname="${CONSOLE_PUBLIC_HOST}" \
  --set agentManagerService.ocIngress.hostname="${API_PUBLIC_HOST}" \
  --set agentManagerService.config.serverPublicURL="${API_PUBLIC_URL}" \
  --set agentManagerService.config.keyManager.issuer="${THUNDER_PUBLIC_URL}" \
  --set agentManagerService.config.keyManager.jwksUrl="${THUNDER_INTERNAL_URL}/oauth2/jwks" \
  --set agentManagerService.config.oidc.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
  --set agentManagerService.config.oidc.clientSecret="${AMP_API_CLIENT_SECRET}" \
  --set agentManagerService.config.thunder.clientSecret="${AMP_SYSTEM_CLIENT_SECRET}" \
  --set agentManagerService.config.thunder.baseURL="${THUNDER_PUBLIC_URL}" \
  --set agentManagerService.config.thunder.resolveToHost="" \
  --set agentManagerService.config.thunderHostBaseDomain="${BASE_DOMAIN}" \
  --set agentManagerService.config.agentsBaseDomain="${AGENTS_DOMAIN}" \
  --set agentManagerService.config.gatewayBaseDomain="${AGENTS_DOMAIN}" \
  --set agentManagerService.config.agentsHttpPort="80" \
  --set agentManagerService.config.agentsHttpsPort="443" \
  --set agentManagerService.config.openChoreo.baseURL="${OPENCHOREO_API_URL}" \
  --set agentManagerService.config.tlsEnabled=true \
  --set agentManagerService.replicaCount=1 \
  --set agentManagerService.autoscaling.enabled=false \
  --set agentManagerService.autoscaling.minReplicas=1 \
  --set console.replicaCount=2 \
  --set agentManagerService.config.openbao.existingSecret=amp-openbao-token \
  --set agentManagerService.config.workflowPlaneOpenbao.existingSecret=amp-openbao-token \
  --set agentManagerService.config.workflowPlaneOpenbao.existingSecretKey=workflow-plane-openbao-token \
  --set postgresql.enabled=false \
  --set postgresql.external.host="${DB_HOST}" \
  --set postgresql.external.port=5432 \
  --set postgresql.external.database="${AMP_DB_NAME}" \
  --set postgresql.external.username="${AMP_DB_USER}" \
  --set postgresql.external.existingSecret=amp-db-credentials \
  --set postgresql.external.existingSecretPasswordKey=password \
  --set postgresql.external.sslMode=require \
  --timeout 1800s

kubectl wait --for=condition=Available deployment/amp-api     -n "${AMP_NS}" --timeout=600s
kubectl wait --for=condition=Available deployment/amp-console -n "${AMP_NS}" --timeout=600s

# ============================================================ Core: sandbox + resources

log "Step 3: agent sandbox module"
helm upgrade --install --server-side=false agent-sandbox \
  oci://ghcr.io/openchoreo/helm-charts/agent-sandbox \
  --version "${AGENT_SANDBOX_VERSION}" \
  --namespace "${DATA_PLANE_NS}" \
  --create-namespace \
  --wait --timeout 10m \
  --set namespace="${CONTROL_PLANE_NS}" \
  --set dataPlaneNamespace="${DATA_PLANE_NS}" \
  --set dataPlaneServiceAccount=cluster-agent-dataplane \
  --set upstream.version=v0.4.6

kubectl wait -n agent-sandbox-system --for=condition=available --timeout=180s \
  deployment/agent-sandbox-controller

log "Step 4: platform resources"
# The four global.oauth/global.apiServer values default to host.k3d.internal,
# which resolves nowhere here. Nothing fails until the first build, which then
# dies on an empty 'Failed to get access token:'.
# apiPlatformGateway.namespace must match where Step 7 installs the INGRESS
# gateway — inbound routing and agent traces both target that half — or they
# silently go to an unresolvable host. Left EMPTY on purpose: the chart then
# derives the runtime host as
# api-platform-<org>-<env>-gw-gateway-gateway-runtime.<org>-<env> from
# OpenChoreo trait placeholders resolved per component, which is precisely where
# split topology puts every environment's ingress half — default-default here,
# default-prod for anything 07-add-environment.sh adds later. Pinning it to one
# namespace would be correct for the default environment and would send every
# other environment's agent traces to the default environment's gateway.
# --reuse-values so a re-run keeps values layered onto this release later: the
# environment gateway hosts (end of this script) and the deployment-pipeline
# promotion targets (07-add-environment.sh). No-op on first install.
helm upgrade --install --server-side=false amp-platform-resources \
  "${CHART_BASE}/wso2-amp-platform-resources-extension" \
  --version "${VERSION}" \
  --namespace "${DEFAULT_NS}" \
  --reuse-values \
  --set global.oauth.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
  --set global.oauth.hostHeader="amp-thunder-extension-service.${THUNDER_NS}.svc.cluster.local" \
  --set global.apiServer.url="${OPENCHOREO_API_URL}" \
  --set global.apiServer.hostHeader="openchoreo-api.${CONTROL_PLANE_NS}.svc.cluster.local" \
  --set apiPlatformGateway.namespace="" \
  --set global.registry.endpoint="${REGISTRY_ENDPOINT}" \
  --set global.defaultResources.registry.tlsVerify=true \
  --timeout 1800s

# ============================================================ Extensions

log "Step 5: observability extension"
# auth.issuer must be the PUBLIC Thunder URL — it validates the same user token
# the console sends, so it has to match keyManager.issuer above.
helm upgrade --install --server-side=false amp-observability-traces \
  "${CHART_BASE}/wso2-amp-observability-extension" \
  --version "${VERSION}" \
  --namespace "${OBSERVABILITY_NS}" \
  --set amObserver.ocIngress.hostname="${OBS_API_PUBLIC_HOST}" \
  --set amObserver.publicUrl="${OBS_API_PUBLIC_URL}" \
  --set amObserver.auth.issuer="${THUNDER_PUBLIC_URL}" \
  --set amObserver.observer.idpClientSecret="${AM_OBSERVER_CLIENT_SECRET}" \
  --set amObserver.replicaCount=2 \
  --timeout 1800s

kubectl wait --for=condition=Available deployment/amp-observer -n "${OBSERVABILITY_NS}" --timeout=600s

log "Step 6: evaluation extension"
helm upgrade --install --server-side=false amp-evaluation-extension \
  "${CHART_BASE}/wso2-amp-evaluation-extension" \
  --version "${VERSION}" \
  --namespace "${BUILD_CI_NS}" \
  --timeout 1800s

log "Step 7: API platform gateway extension (split INGRESS/EGRESS)"
prepare_gateway_namespace "${INGRESS_NS}"
prepare_gateway_namespace "${EGRESS_NS}"

# gateway.vhost, gateway.hostname and gateway.type are written into Agent Manager
# at FIRST registration only. A later helm upgrade logs 'already exists' and
# reconciles nothing, so these must be right now.
install_gateway_half() {
  local release="$1" ns="$2" type="$3" host="$4" display="$5"
  if helm status "$release" -n "$ns" >/dev/null 2>&1; then
    warn "${release} already installed — its registered role and vhost are frozen, skipping install."
    return 0
  fi
  # gateway.name is set explicitly on both halves: the chart defaults it to
  # api-platform-<org>-<env>, so the egress release would otherwise register the
  # same gateway name and claim the same hostname as the ingress half.
  helm install --server-side=false "$release" \
    "${CHART_BASE}/wso2-amp-api-platform-gateway-extension" \
    --version "${VERSION}" \
    --namespace "$ns" \
    --set agentManager.orgName="${GW_ORG}" \
    --set gateway.environment="${GW_ENV}" \
    --set apiGateway.namespace="$ns" \
    --set gateway.name="$release" \
    --set gateway.type="$type" \
    --set gateway.displayName="$display" \
    --set developmentMode=false \
    --set gateway.vhost="https://${host}" \
    --set gateway.hostname="${host}" \
    --set agentManager.idp.existingSecret=gateway-idp-credentials \
    --timeout 1800s
}

install_gateway_half "${INGRESS_RELEASE}" "${INGRESS_NS}" INGRESS \
  "${INGRESS_HOST}" "Default API Platform Gateway"
install_gateway_half "${EGRESS_RELEASE}" "${EGRESS_NS}" EGRESS \
  "${EGRESS_HOST}" "Default API Platform Gateway (Egress)"

# The bootstrap Job only exists right after a fresh install — it is a helm
# hook that gets cleaned up later, so on re-runs (install skipped above) there
# is nothing to wait for.
wait_for_bootstrap() {
  local release="$1" ns="$2"
  if kubectl get job "${release}-bootstrap" -n "$ns" >/dev/null 2>&1; then
    kubectl wait --for=condition=complete "job/${release}-bootstrap" \
      -n "$ns" --timeout=600s
  fi
}
wait_for_bootstrap "${INGRESS_RELEASE}" "${INGRESS_NS}"
wait_for_bootstrap "${EGRESS_RELEASE}" "${EGRESS_NS}"

kubectl wait --for=condition=Programmed "apigateway/${INGRESS_RELEASE}" \
  -n "${INGRESS_NS}" --timeout=300s
kubectl wait --for=condition=Programmed "apigateway/${EGRESS_RELEASE}" \
  -n "${EGRESS_NS}" --timeout=300s

# ============================================================ Remaining endpoints

log "Wiring the external AI gateway endpoint"
helm upgrade amp "${CHART_BASE}/wso2-agent-manager" \
  --version "${VERSION}" \
  --namespace "${AMP_NS}" \
  --reuse-values \
  --set "agentManagerService.ocIngress.gatewayMgmt.hostnames={${CP_GW_PUBLIC_HOST}}" \
  --set console.config.gatewayControlPlaneUrl="https://${CP_GW_PUBLIC_HOST}"

log "Pointing the default Environment's gateway at ${AGENTS_DOMAIN}"
# The Environment's gateway binding wholly replaces the data plane's, so both
# variants must be set, each on the port its listener actually serves. Putting
# 443 on the http variant publishes http://host:443, which browsers block.
helm upgrade amp-platform-resources \
  "${CHART_BASE}/wso2-amp-platform-resources-extension" \
  --version "${VERSION}" \
  --namespace "${DEFAULT_NS}" \
  --reuse-values \
  --set global.oauth.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
  --set environment.gateway.http.host="${AGENTS_DOMAIN}" \
  --set environment.gateway.http.port=80 \
  --set environment.gateway.https.host="${AGENTS_DOMAIN}" \
  --set environment.gateway.https.port=443

# ============================================================ env-Thunder

log "Provisioning env-Thunder for the default Environment"
SCRIPT="${SECRETS_DIR}/add-environment-thunder.sh"
curl -fsSL "${RAW_BASE}/deployments/scripts/add-environment-thunder.sh" -o "${SCRIPT}"

# rc1 made env-Thunder hostnames handle-based: <handle>.${BASE_DOMAIN}, with the
# handle registered against agent-manager-service (PUT .../thunder-url) BEFORE
# any cluster mutation, so a collision fails fast instead of orphaning a Helm
# release. Passing an explicit handle is what makes this step re-runnable — that
# PUT upserts for the same (org, env), so a re-run resolves to the same host and
# the same issuer. Omit it and the script mints a fresh generated handle whose
# value is only discoverable by reading back what it printed.
ENV_HANDLE="$(env_thunder_handle "${GW_ORG}" "${GW_ENV}")"
echo "  env-Thunder host: ${ENV_HANDLE}.${BASE_DOMAIN}"

# IDP_CLIENT_SECRET defaults to the shipped placeholder, which fails against a
# real install. SKIP_CA_BUNDLE_TRUST is safe here only because the certificates
# are publicly trusted Let's Encrypt ones.
ENV_NAME=default \
DISPLAY_NAME="Default" \
ORG_NAME=default \
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

kubectl get pods -n amp-thunder-default-default

log "env-Thunder console admin password (not shown again elsewhere)"
kubectl get secret amp-thunder-default-default-admin-credentials \
  -n amp-thunder-default-default -o jsonpath='{.data.password}' | base64 -d \
  | tee "${SECRETS_DIR}/env-thunder-admin-password.txt"
echo
chmod 600 "${SECRETS_DIR}/env-thunder-admin-password.txt"

# ============================================================ Gateway key managers

log "Registering env-Thunder as a gateway key manager"
# Both key managers must be restated: helm --set on an indexed array replaces the
# whole list, and dropping index 0 would break API-key authentication.
ENV_THUNDER_RELEASE="amp-thunder-default-default"
ENV_THUNDER_ISSUER="https://${ENV_HANDLE}.${BASE_DOMAIN}"
ENV_THUNDER_JWKS="http://${ENV_THUNDER_RELEASE}-service.${ENV_THUNDER_RELEASE}.svc.cluster.local:8090/oauth2/jwks"
AM_JWKS="http://amp-api.${AMP_NS}.svc.cluster.local:9000/auth/external/jwks.json"

# Applied to both halves of the split gateway: each release carries its own
# policy configuration, and an EGRESS gateway that cannot validate env-Thunder
# tokens fails the same way an INGRESS one does.
for gw in "${INGRESS_RELEASE}:${INGRESS_NS}" "${EGRESS_RELEASE}:${EGRESS_NS}"; do
  helm upgrade "${gw%%:*}" \
    "${CHART_BASE}/wso2-amp-api-platform-gateway-extension" \
    --version "${VERSION}" \
    --namespace "${gw##*:}" \
    --reuse-values \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].name=agent-manager-service" \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].issuer=agent-manager-service" \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].jwks.remote.uri=${AM_JWKS}" \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].jwks.remote.skipTlsVerify=true" \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].name=ThunderKeyManager" \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].issuer=${ENV_THUNDER_ISSUER}" \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].jwks.remote.uri=${ENV_THUNDER_JWKS}" \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].jwks.remote.skipTlsVerify=false" \
    --set "bootstrap.identityProviders[0].name=ThunderKeyManager" \
    --set "bootstrap.identityProviders[0].issuer=${ENV_THUNDER_ISSUER}" \
    --set "bootstrap.identityProviders[0].jwksUri=${ENV_THUNDER_JWKS}" \
    --set "bootstrap.identityProviders[0].skipTlsVerify=false" \
    --timeout 900s
done

# ============================================================ Verify

log "Verification"
kubectl get apigateway "${INGRESS_RELEASE}" -n "${INGRESS_NS}" || true
kubectl get apigateway "${EGRESS_RELEASE}"  -n "${EGRESS_NS}"  || true
kubectl get pods -n "${AMP_NS}"

# The API's health endpoint is /healthz (moved off /health in the 20260806
# nightly); the observer still serves /health.
for url in "${API_PUBLIC_URL}/healthz" "${OBS_API_PUBLIC_URL}/health" "${CONSOLE_PUBLIC_URL}/"; do
  printf '  %-60s %s\n' "$url" "$(curl -s -o /dev/null -w '%{http_code}' "$url" || echo unreachable)"
done

cat <<SUMMARY

$(printf '\033[1;32m')Install complete.$(printf '\033[0m')

  Console        ${CONSOLE_PUBLIC_URL}
  API            ${API_PUBLIC_URL}
  Observer       ${OBS_API_PUBLIC_URL}
  Thunder        ${THUNDER_PUBLIC_URL}
  Agents         https://<agent>.${AGENTS_DOMAIN}
  Registry       ${REGISTRY_ENDPOINT} (VPC-internal)

  Default environment gateways (split topology):
    Ingress      https://${INGRESS_HOST}   (ns ${INGRESS_NS})
    Egress       ${EGRESS_HOST}            (ns ${EGRESS_NS})

  Secrets, OpenBao unseal keys and the env-Thunder admin password are in
  ${SECRETS_DIR}. Move them into a secret manager and keep them: OpenBao's
  unseal keys are needed after every pod restart.

  Tear everything down with ./99-teardown.sh
SUMMARY
