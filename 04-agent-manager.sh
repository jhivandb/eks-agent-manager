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

log "Step 1: gateway operator 0.10.1"
# gateway.helm.chartVersion must be pinned to 1.2.0-beta. The operator defaults
# to 1.2.0-alpha, whose templates predate the controller reading its
# control-plane address from config, giving a gateway that serves traffic but
# never registers with Agent Manager.
helm upgrade --install --server-side=false gateway-operator \
  oci://ghcr.io/wso2/api-platform/helm-charts/gateway-operator \
  --version 0.10.1 \
  --namespace "${DATA_PLANE_NS}" \
  --set logging.level=info \
  --set gatewayApi.installStandardCRDs=false \
  --set gateway.helm.chartVersion=1.2.0-beta \
  --set gateway.values.gateway.controller.encryptionKeys.enabled=true \
  --set gateway.values.gateway.controller.encryptionKeys.secretName=gateway-encryption-keys \
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
# Both replicaCount and autoscaling.minReplicas are needed — the HPA is on by
# default and would scale replicaCount straight back to 1.
helm upgrade --install --server-side=false amp \
  "${CHART_BASE}/wso2-agent-manager" \
  --version "${VERSION}" \
  --namespace "${AMP_NS}" \
  --create-namespace \
  --set console.config.instrumentationUrl="${INSTRUMENTATION_URL}" \
  --set console.config.auth.baseUrl="${THUNDER_PUBLIC_URL}" \
  --set console.config.auth.signInRedirectURL="${CONSOLE_PUBLIC_URL}/login" \
  --set console.config.auth.signOutRedirectURL="${CONSOLE_PUBLIC_URL}/login" \
  --set console.config.apiBaseUrl="${API_PUBLIC_URL}" \
  --set agentManagerService.config.amObserverPublicURL="${OBS_API_PUBLIC_URL}" \
  --set console.ocIngress.hostname="${CONSOLE_PUBLIC_HOST}" \
  --set agentManagerService.ocIngress.hostname="${API_PUBLIC_HOST}" \
  --set agentManagerService.config.serverPublicURL="${API_PUBLIC_URL}" \
  --set agentManagerService.config.keyManager.issuer="${THUNDER_PUBLIC_URL}" \
  --set agentManagerService.config.keyManager.jwksUrl="${THUNDER_INTERNAL_URL}/oauth2/jwks" \
  --set agentManagerService.config.oidc.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
  --set agentManagerService.config.oidc.clientSecret="${AMP_API_CLIENT_SECRET}" \
  --set agentManagerService.config.thunder.clientSecret="${AMP_SYSTEM_CLIENT_SECRET}" \
  --set agentManagerService.config.openChoreo.baseURL="${OPENCHOREO_API_URL}" \
  --set agentManagerService.config.tlsEnabled=true \
  --set agentManagerService.replicaCount=2 \
  --set agentManagerService.autoscaling.minReplicas=2 \
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
  --version 0.1.1 \
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
# apiPlatformGateway.namespace must match where Step 7 installs the gateway, or
# agent traces and inbound routing both silently go to an unresolvable host.
helm upgrade --install --server-side=false amp-platform-resources \
  "${CHART_BASE}/wso2-amp-platform-resources-extension" \
  --version "${VERSION}" \
  --namespace "${DEFAULT_NS}" \
  --set global.oauth.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
  --set global.oauth.hostHeader="amp-thunder-extension-service.${THUNDER_NS}.svc.cluster.local" \
  --set global.apiServer.url="${OPENCHOREO_API_URL}" \
  --set global.apiServer.hostHeader="openchoreo-api.${CONTROL_PLANE_NS}.svc.cluster.local" \
  --set apiPlatformGateway.namespace="${DATA_PLANE_NS}" \
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

log "Step 7: API platform gateway extension"
kubectl create secret generic gateway-idp-credentials \
  --namespace "${DATA_PLANE_NS}" \
  --from-literal=client-id=amp-api-client \
  --from-literal=client-secret="${AMP_API_CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

# gateway.vhost and gateway.hostname are written into Agent Manager at FIRST
# registration only. A later helm upgrade logs 'already exists' and reconciles
# nothing, so these must be right now.
if helm status api-platform-default-default -n "${DATA_PLANE_NS}" >/dev/null 2>&1; then
  warn "Gateway extension already installed — its registered vhost is frozen, skipping install."
else
  helm install --server-side=false api-platform-default-default \
    "${CHART_BASE}/wso2-amp-api-platform-gateway-extension" \
    --version "${VERSION}" \
    --namespace "${DATA_PLANE_NS}" \
    --set agentManager.orgName=default \
    --set gateway.environment=default \
    --set gateway.type=BOTH \
    --set developmentMode=false \
    --set gateway.vhost="https://default-default.${AGENTS_DOMAIN}" \
    --set gateway.hostname="default-default.${AGENTS_DOMAIN}" \
    --set agentManager.idp.existingSecret=gateway-idp-credentials \
    --timeout 1800s
fi

kubectl wait --for=condition=complete job/api-platform-default-default-bootstrap \
  -n "${DATA_PLANE_NS}" --timeout=600s

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
ENV_THUNDER_ISSUER="https://default-default.thunder.${BASE_DOMAIN}"
ENV_THUNDER_JWKS="http://${ENV_THUNDER_RELEASE}-service.${ENV_THUNDER_RELEASE}.svc.cluster.local:8090/oauth2/jwks"

helm upgrade api-platform-default-default \
  "${CHART_BASE}/wso2-amp-api-platform-gateway-extension" \
  --version "${VERSION}" \
  --namespace "${DATA_PLANE_NS}" \
  --reuse-values \
  --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].name=agent-manager-service" \
  --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].issuer=agent-manager-service" \
  --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].jwks.remote.uri=http://amp-api.${AMP_NS}.svc.cluster.local:9000/auth/external/jwks.json" \
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

# ============================================================ Verify

log "Verification"
kubectl get apigateway api-platform-default-default -n "${DATA_PLANE_NS}" || true
kubectl get pods -n "${AMP_NS}"

for url in "${API_PUBLIC_URL}/health" "${OBS_API_PUBLIC_URL}/health" "${CONSOLE_PUBLIC_URL}/"; do
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

  Secrets, OpenBao unseal keys and the env-Thunder admin password are in
  ${SECRETS_DIR}. Move them into a secret manager and keep them: OpenBao's
  unseal keys are needed after every pod restart.

  Tear everything down with ./99-teardown.sh
SUMMARY
