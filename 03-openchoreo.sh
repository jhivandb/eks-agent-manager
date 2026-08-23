#!/usr/bin/env bash
# Phase 1 of the agent-manager guide: the OpenChoreo platform and Thunder.
#
# Follows documentation/docs/getting-started/on-your-environment.mdx, Steps 1-10,
# production variants throughout. Deviations from the doc are commented inline.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

require_placeholders_filled
kubeconfig_points_at_cluster
source "${SECRETS_DIR}/db-endpoint.env"
export THUNDER_DB_HOST="${DB_HOST}"

BAO_INIT_FILE="${SECRETS_DIR}/openbao-init.json"

# ============================================================ Step 1: cluster prereqs

log "Step 1: Gateway API CRDs v1.4.1"
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/experimental-install.yaml

log "Step 1: IAM role for cert-manager's Route 53 DNS-01 solver"
# The doc passes a long-lived IAM access key. Pod identity avoids putting one in
# a cluster Secret; cert-manager then picks up ambient credentials and the
# solver only needs the region.
POLICY_NAME="${CLUSTER_NAME}-cert-manager-route53"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
if ! aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  aws iam create-policy --policy-name "${POLICY_NAME}" --policy-document "$(jq -n \
    --arg zone "arn:aws:route53:::hostedzone/${ROUTE53_ZONE_ID}" '{
      Version: "2012-10-17",
      Statement: [
        {Effect:"Allow", Action:"route53:GetChange", Resource:"arn:aws:route53:::change/*"},
        {Effect:"Allow", Action:["route53:ChangeResourceRecordSets","route53:ListResourceRecordSets"], Resource:$zone},
        {Effect:"Allow", Action:"route53:ListHostedZonesByName", Resource:"*"}
      ]}')" >/dev/null
fi
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
eksctl create iamserviceaccount \
  --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --namespace cert-manager --name cert-manager \
  --attach-policy-arn "${POLICY_ARN}" \
  --approve --override-existing-serviceaccounts

log "Step 1: cert-manager v1.19.2"
helm upgrade --install --server-side=false cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.19.2 \
  --set crds.enabled=true \
  --set startupapicheck.timeout=5m \
  --set serviceAccount.create=false \
  --set serviceAccount.name=cert-manager \
  --set securityContext.fsGroup=1001 \
  --wait --timeout 360s

log "Step 1: External Secrets Operator v1.3.2"
helm upgrade --install --server-side=false external-secrets oci://ghcr.io/external-secrets/charts/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --version 1.3.2 \
  --set installCRDs=true \
  --wait --timeout 180s

log "Step 1: kgateway v2.2.1"
helm upgrade --install --server-side=false kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
  --create-namespace --namespace "${CONTROL_PLANE_NS}" --version v2.2.1
helm upgrade --install --server-side=false kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
  --namespace "${CONTROL_PLANE_NS}" --create-namespace --version v2.2.1 \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

# ============================================================ Step 2: OpenBao

log "Step 2: OpenBao (sealed, persistent)"
helm upgrade --install --server-side=false openbao oci://ghcr.io/openbao/charts/openbao \
  --namespace openbao --create-namespace --version 0.25.6 \
  --set server.dataStorage.size=10Gi --timeout 180s

# A sealed OpenBao never reports Ready, and pod conditions are set before the
# container starts, so kubectl wait has nothing safe to wait on — exec'ing on
# a condition races the container. Poll until bao itself answers: status exits
# 0 when unsealed, 2 when sealed-but-responding; anything else is "not up yet".
log "Step 2: waiting for the openbao container to answer"
for i in $(seq 1 60); do
  rc=0
  kubectl exec -n openbao openbao-0 -- \
    sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao status' >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 0 || $rc -eq 2 ]] && break
  [[ $i -eq 60 ]] && die "openbao-0 never started responding on :8200"
  sleep 5
done

# Ask OpenBao whether it is initialised rather than inferring it from the file.
# The file is not evidence: 99-teardown.sh deliberately leaves .secrets/ in
# place, so a keyfile from a destroyed cluster outlives it and a non-empty
# `[[ -s ]]` check reads as "already initialised" on a brand-new instance —
# which then fails the unseal with "Vault is not initialized".
bao_initialized="$(kubectl exec -n openbao openbao-0 -- \
  sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao status -format=json 2>/dev/null || true' \
  | jq -r '.initialized // "false"')"

if [[ "${bao_initialized}" == "true" ]]; then
  [[ -s "${BAO_INIT_FILE}" ]] || die "OpenBao is initialised but ${BAO_INIT_FILE} is missing or empty. Its unseal keys are the only way into that PVC — recover the file; do NOT re-initialise."
  warn "OpenBao already initialised — reusing keys from ${BAO_INIT_FILE}"
else
  log "Step 2: initialising OpenBao"
  umask 077
  # Initialized:false means no keys have ever existed here, so anything at this
  # path belongs to a previous cluster. Archived rather than deleted: it is
  # still key material, just for a PVC that no longer exists.
  if [[ -s "${BAO_INIT_FILE}" ]]; then
    stale_keys="${BAO_INIT_FILE}.stale-$(date +%Y%m%d%H%M%S)"
    mv "${BAO_INIT_FILE}" "${stale_keys}"
    warn "OpenBao is uninitialised but ${BAO_INIT_FILE} existed — keys from an earlier cluster."
    warn "Archived to ${stale_keys}; initialising fresh."
  fi
  rm -f "${BAO_INIT_FILE}"
  # Init writes to a temp file first: `> file` truncates before exec starts,
  # so a failed exec would leave a zero-byte file that a later run would
  # mistake for real keys and skip init entirely.
  kubectl exec -n openbao openbao-0 -- \
    bao operator init -key-shares=5 -key-threshold=3 -format=json > "${BAO_INIT_FILE}.tmp"
  jq -e '.root_token and (.unseal_keys_b64 | length == 5)' "${BAO_INIT_FILE}.tmp" >/dev/null \
    || die "bao operator init output is incomplete — inspect ${BAO_INIT_FILE}.tmp"
  mv "${BAO_INIT_FILE}.tmp" "${BAO_INIT_FILE}"
  chmod 600 "${BAO_INIT_FILE}"
  warn "Unseal keys and root token written to ${BAO_INIT_FILE}."
  warn "Move them into a secret manager — without them the PVC is unrecoverable."
fi

BAO_ROOT_TOKEN="$(jq -r '.root_token' "${BAO_INIT_FILE}")"
[[ -n "${BAO_ROOT_TOKEN}" && "${BAO_ROOT_TOKEN}" != "null" ]] \
  || die "no root token in ${BAO_INIT_FILE} — if OpenBao is initialised, do NOT delete this file; recover it"

sealed="$(kubectl exec -n openbao openbao-0 -- \
  sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao status -format=json 2>/dev/null || true' \
  | jq -r '.sealed // "true"')"
if [[ "$sealed" == "true" ]]; then
  log "Step 2: unsealing with 3 of 5 keys"
  for i in 0 1 2; do
    key="$(jq -r ".unseal_keys_b64[$i]" "${BAO_INIT_FILE}")"
    kubectl exec -n openbao openbao-0 -- bao operator unseal "$key" >/dev/null
  done
fi
kubectl wait --for=condition=Ready pod/openbao-0 -n openbao --timeout=180s

log "Step 2: configuring KV mount, Kubernetes auth and seeding secrets"
# Every command is written to tolerate re-runs; bao errors on re-enabling a mount.
kubectl exec -n openbao openbao-0 -- sh -c "
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN='${BAO_ROOT_TOKEN}'
set -e

bao secrets enable -path=secret -version=2 kv 2>/dev/null || true
bao auth enable kubernetes 2>/dev/null || true
bao write auth/kubernetes/config kubernetes_host=\"https://\$KUBERNETES_PORT_443_TCP_ADDR:443\"

bao policy write openchoreo-secret-reader-policy - <<POLICY
path \"secret/data/*\" { capabilities = [\"read\"] }
path \"secret/metadata/*\" { capabilities = [\"list\", \"read\"] }
POLICY

bao policy write openchoreo-secret-writer-policy - <<POLICY
path \"secret/data/*\" { capabilities = [\"create\", \"read\", \"update\", \"delete\"] }
path \"secret/metadata/*\" { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\"] }
POLICY

bao write auth/kubernetes/role/openchoreo-secret-reader-role \
  bound_service_account_names=default \
  bound_service_account_namespaces='dp*' \
  policies=openchoreo-secret-reader-policy ttl=20m

bao write auth/kubernetes/role/openchoreo-secret-writer-role \
  bound_service_account_names='*' \
  bound_service_account_namespaces='openbao,${BUILD_CI_NS},${AMP_NS}' \
  policies=openchoreo-secret-writer-policy ttl=20m

bao kv put secret/workflow-plane-oauth-client-secret value='${WORKFLOW_PUBLISHER_SECRET}'
bao kv put secret/amp-publisher-client-secret value='${AMP_PUBLISHER_CLIENT_SECRET}'
bao kv put secret/amp-system-client-secret value='${AMP_SYSTEM_CLIENT_SECRET}'
bao kv put secret/observer-oauth-client-secret value='${OBSERVER_READER_SECRET}'
bao kv put secret/opensearch-username value='${OPENSEARCH_USERNAME}'
bao kv put secret/opensearch-password value='${OPENSEARCH_PASSWORD}'
"

log "Step 2: minting the Agent Manager's OpenBao token"
# The chart otherwise defaults to the dev-mode token 'root', which a sealed
# OpenBao rejects — and the failure only surfaces as a 500 on agent creation.
AMP_BAO_TOKEN="$(kubectl exec -n openbao openbao-0 -- sh -c "
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN='${BAO_ROOT_TOKEN}'
bao token create -policy=openchoreo-secret-writer-policy -period=768h -format=json" \
  | jq -r '.auth.client_token')"

kubectl create namespace "${AMP_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic amp-openbao-token -n "${AMP_NS}" \
  --from-literal=openbao-token="${AMP_BAO_TOKEN}" \
  --from-literal=workflow-plane-openbao-token="${AMP_BAO_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -
warn "The OpenBao token has a 768h period. Renew it before then or agent creation starts failing."

log "Step 2: ClusterSecretStore"
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets-openbao
  namespace: openbao
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: default
spec:
  provider:
    vault:
      server: "http://openbao.openbao.svc:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "openchoreo-secret-writer-role"
          serviceAccountRef:
            name: "external-secrets-openbao"
            namespace: "openbao"
EOF

# ============================================================ Step 3: TLS issuer

log "Step 3: Let's Encrypt DNS-01 ClusterIssuer"
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: openchoreo-ca
spec:
  acme:
    server: ${ACME_SERVER}
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - dns01:
          route53:
            region: ${AWS_REGION}
            hostedZoneID: ${ROUTE53_ZONE_ID}
        selector:
          dnsZones:
            - "${BASE_DOMAIN#amp.}"
EOF
kubectl wait --for=condition=Ready clusterissuer/openchoreo-ca --timeout=180s

# ============================================================ Step 4: Thunder

log "Step 4: Thunder on external PostgreSQL"
kubectl create namespace "${THUNDER_NS}" --dry-run=client -o yaml | kubectl apply -f -

THUNDER_VALUES="${SECRETS_DIR}/thunder-db-values.yaml"
{
  echo "thunder:"
  echo "  configuration:"
  echo "    database:"
  # Datasource key -> database name. Every key the chart declares must appear
  # here: an unrecognised key is dropped without warning, and one that is simply
  # absent keeps the chart default of SQLite on a PVC. Both are silent, so a
  # stale map does not fail the install — it strands Thunder's state on one
  # pod's disk while the release reports healthy. Keys come from
  # charts/thunderid/templates/secret.yaml; the databases are THUNDER_DBS.
  for pair in "config:configdb" "entity:entitydb" \
              "runtime_persistent:runtime_persistent" \
              "runtime_transient:runtime_transient"; do
    key="${pair%%:*}"; db="${pair##*:}"
    cat <<EOF
      ${key}:
        type: postgres
        postgres:
          hostname: "${THUNDER_DB_HOST}"
          port: "5432"
          name: ${db}
          username: ${THUNDER_DB_USER}
          sslmode: require
          passwordRef:
            name: thunder-db-credentials
            key: password
EOF
  done
} > "${THUNDER_VALUES}"

if helm status amp-thunder-extension -n "${THUNDER_NS}" >/dev/null 2>&1; then
  warn "Thunder already installed. Its issuer, redirect URIs and client secrets are"
  warn "frozen in its database — skipping rather than attempting an upgrade."
else
  # All six bootstrap client secrets must be passed. Any omitted one keeps the
  # chart's shipped default while its consumer reads the generated value from
  # OpenBao, and builds then fail with an unlogged 401 invalid_client.
  #
  # ocIngress.https.enabled defaults to true, which stands up a second dedicated
  # Gateway and a self-signed "AMP Local Dev CA" certificate so that a k3d
  # install can reach Thunder over HTTPS without the control plane's gateway TLS.
  # Every plane here already has its own LoadBalancer and a real wildcard
  # certificate, so that Gateway and CA would only be an unused load balancer.
  helm install --server-side=false amp-thunder-extension \
    "oci://${HELM_CHART_REGISTRY}/wso2-amp-thunder-extension" \
    --version "${VERSION}" \
    --namespace "${THUNDER_NS}" \
    --create-namespace \
    --set thunder.ocIngress.hostname="${THUNDER_PUBLIC_HOST}" \
    --set thunder.ocIngress.https.enabled=false \
    --set thunder.configuration.server.publicUrl="${THUNDER_PUBLIC_URL}" \
    --set thunder.configuration.jwt.issuer="${THUNDER_PUBLIC_URL}" \
    --set thunder.configuration.gateClient.hostname="${THUNDER_PUBLIC_HOST}" \
    --set thunder.configuration.gateClient.scheme=https \
    --set thunder.configuration.gateClient.port=443 \
    --set "thunder.configuration.cors.allowedOrigins={${CONSOLE_PUBLIC_URL}}" \
    --set "thunder.bootstrap.ampConsoleClient.redirectUris={${CONSOLE_PUBLIC_URL}/login}" \
    --set thunder.bootstrap.agentManagerMcpBaseUrl="${API_PUBLIC_URL}" \
    --set thunder.bootstrap.observerMcpBaseUrl="${OBS_API_PUBLIC_URL}" \
    --set thunder.bootstrap.ampApiClient.clientSecret="${AMP_API_CLIENT_SECRET}" \
    --set thunder.bootstrap.ampSystemClient.clientSecret="${AMP_SYSTEM_CLIENT_SECRET}" \
    --set thunder.bootstrap.ampPublisherClient.clientSecret="${AMP_PUBLISHER_CLIENT_SECRET}" \
    --set thunder.bootstrap.amObserverClient.clientSecret="${AM_OBSERVER_CLIENT_SECRET}" \
    --set thunder.bootstrap.workloadPublisherClient.clientSecret="${WORKFLOW_PUBLISHER_SECRET}" \
    --set thunder.bootstrap.observerResourceReaderClient.clientSecret="${OBSERVER_READER_SECRET}" \
    --values "${THUNDER_VALUES}" \
    --timeout 1800s
fi

kubectl wait --for=condition=Available \
  deployment -l app.kubernetes.io/instance=amp-thunder-extension \
  -n "${THUNDER_NS}" --timeout=300s

log "Step 4: platform console admin password (generated, shown nowhere else)"
# rc1 dropped `password: "admin"` from the chart's defaultUsers entry. An
# admin-credentials.yaml template now resolves the password from
# thunder.setup.admin.password, else a previously stored value, else
# randAlphaNum 10, and writes it to this Secret — and leaving the value unset,
# as this install does, is the documented production path. So this read is the
# only way to learn it. The Secret comes from a pre-install hook at weight -20,
# which is why it is also there on the already-installed path above.
kubectl get secret amp-admin-credentials -n "${THUNDER_NS}" \
  -o jsonpath='{.data.password}' | base64 -d \
  | tee "${SECRETS_DIR}/console-admin-password.txt"
echo
chmod 600 "${SECRETS_DIR}/console-admin-password.txt"

log "Step 4 verify: issuer must equal ${THUNDER_PUBLIC_URL}"
kubectl exec -n "${THUNDER_NS}" deploy/amp-thunder-extension-deployment -- \
  wget -qO- http://localhost:8090/.well-known/openid-configuration 2>/dev/null \
  | grep -o '"issuer":"[^"]*"' || warn "could not read the issuer"

# ============================================================ Step 5: control plane

log "Step 5: control-plane wildcard certificate"
kubectl create namespace "${CONTROL_PLANE_NS}" --dry-run=client -o yaml | kubectl apply -f -
# Two names, not the three this used to carry: rc1's env-Thunder hosts are
# <handle>.${BASE_DOMAIN}, a single label, so the *.${BASE_DOMAIN} wildcard
# already covers them. The retired <org>-<env>.thunder.${BASE_DOMAIN} shape
# needed a nested *.thunder wildcard because a DNS wildcard matches one label.
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cp-gateway-tls
  namespace: ${CONTROL_PLANE_NS}
spec:
  secretName: cp-gateway-tls
  issuerRef:
    name: openchoreo-ca
    kind: ClusterIssuer
  dnsNames:
    - "*.${BASE_DOMAIN}"
    - "${BASE_DOMAIN}"
  privateKey:
    rotationPolicy: Always
EOF
kubectl wait --for=condition=Ready certificate/cp-gateway-tls -n "${CONTROL_PLANE_NS}" --timeout=600s

log "Step 5: OpenChoreo control plane ${OPENCHOREO_VERSION} CRDs"
# The chart keeps its CRDs in crds/, which Helm installs on first install and
# NEVER touches on upgrade. So bumping OPENCHOREO_VERSION alone leaves the older
# CRD set in place, and the failure lands two scripts later: 04's platform
# resources chart dies with `no matches for kind "ClusterProjectType"`. Applied
# explicitly here so an upgrade picks up new kinds. Not pruned — removing a CRD
# deletes every object of that kind.
CRD_TMP="$(mktemp -d)"
helm pull oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
  --version "${OPENCHOREO_VERSION}" --untar --untardir "${CRD_TMP}" >/dev/null
kubectl apply --server-side --force-conflicts \
  -f "${CRD_TMP}/openchoreo-control-plane/crds/" >/dev/null
rm -rf "${CRD_TMP}"

log "Step 5: OpenChoreo control plane ${OPENCHOREO_VERSION}"
install_control_plane() {
  helm upgrade --install --server-side=false openchoreo-control-plane \
    oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
    --version "${OPENCHOREO_VERSION}" \
    --namespace "${CONTROL_PLANE_NS}" \
    --create-namespace \
    --values - <<EOF
features:
  secretManagement:
    enabled: true
openchoreoApi:
  config:
    server:
      publicUrl: "${OPENCHOREO_API_URL}"
  http:
    enabled: false
    hostnames:
      - "api.${BASE_DOMAIN}"
backstage:
  enabled: false
  baseUrl: ""
  http:
    hostnames:
      - ""
security:
  oidc:
    issuer: "${THUNDER_PUBLIC_URL}"
    wellKnownEndpoint: "${THUNDER_INTERNAL_URL}/.well-known/openid-configuration"
    jwksUrl: "${THUNDER_INTERNAL_URL}/oauth2/jwks"
    authorizationUrl: "${THUNDER_PUBLIC_URL}/oauth2/authorize"
    tokenUrl: "${THUNDER_INTERNAL_URL}/oauth2/token"
gateway:
  tls:
    enabled: true
    hostname: "*.${BASE_DOMAIN}"
    certificateRefs:
      - name: cp-gateway-tls
EOF
}
# The chart has a known race where the chart's webhook has no endpoints yet.
install_control_plane || {
  warn "control-plane install failed — waiting for the webhook and retrying once"
  kubectl wait --for=condition=Available deployment --all -n "${CONTROL_PLANE_NS}" --timeout=300s || true
  install_control_plane
}
kubectl wait --for=condition=Available deployment --all -n "${CONTROL_PLANE_NS}" --timeout=300s

log "Step 5: patching the service-account entitlement claim to client_id"
# Thunder >=0.45 puts the client name in client_id; OpenChoreo reads sub.
# Unpatched, every service-to-service call is silently unauthorized: 200s with
# empty lists, and the gateway bootstrap later fails on 'Environment not found'.
patch_entitlement_claim() {
  local cm="$1" ns="$2"
  kubectl get configmap "$cm" -n "$ns" -o yaml \
    | sed -E "s/claim:[[:space:]]*['\"]?sub['\"]?/claim: client_id/g" \
    | kubectl apply --server-side --field-manager=helm --force-conflicts -f -
}
patch_entitlement_claim openchoreo-api-config "${CONTROL_PLANE_NS}"
kubectl rollout restart deployment/openchoreo-api -n "${CONTROL_PLANE_NS}"
kubectl rollout status deployment/openchoreo-api -n "${CONTROL_PLANE_NS}" --timeout=180s

for binding in $(kubectl get clusterauthzrolebindings.openchoreo.dev -o jsonpath='{.items[*].metadata.name}'); do
  claim="$(kubectl get clusterauthzrolebinding.openchoreo.dev "$binding" -o jsonpath='{.spec.entitlement.claim}')"
  if [[ "$claim" == "sub" ]]; then
    kubectl patch clusterauthzrolebinding.openchoreo.dev "$binding" --type=merge \
      -p '{"spec":{"entitlement":{"claim":"client_id"}}}'
  fi
done

# ============================================================ Step 6: data plane

copy_gateway_ca() {
  local ns="$1"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  local ca crt key
  ca="$(kubectl get secret cluster-gateway-ca -n "${CONTROL_PLANE_NS}" -o jsonpath='{.data.ca\.crt}' | base64 -d)"
  crt="$(kubectl get secret cluster-gateway-ca -n "${CONTROL_PLANE_NS}" -o jsonpath='{.data.tls\.crt}' | base64 -d)"
  key="$(kubectl get secret cluster-gateway-ca -n "${CONTROL_PLANE_NS}" -o jsonpath='{.data.tls\.key}' | base64 -d)"
  kubectl create configmap cluster-gateway-ca --from-literal=ca.crt="$ca" \
    -n "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic cluster-gateway-ca \
    --from-literal=tls.crt="$crt" --from-literal=tls.key="$key" --from-literal=ca.crt="$ca" \
    -n "$ns" --dry-run=client -o yaml | kubectl apply -f -
}

register_plane() {
  local kind="$1" ns="$2" extra="$3"
  local ca
  ca="$(kubectl get secret cluster-agent-tls -n "$ns" -o jsonpath='{.data.ca\.crt}' | base64 -d)"
  kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: ${kind}
metadata:
  name: default
  namespace: default
spec:
  planeID: default
  clusterAgent:
    clientCA:
      value: |
$(echo "$ca" | sed 's/^/        /')
${extra}
EOF
}

log "Step 6: data plane"
copy_gateway_ca "${DATA_PLANE_NS}"
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: dp-gateway-tls
  namespace: ${DATA_PLANE_NS}
spec:
  secretName: dp-gateway-tls
  issuerRef:
    name: openchoreo-ca
    kind: ClusterIssuer
  dnsNames:
    - "*.${AGENTS_DOMAIN}"
    - "${AGENTS_DOMAIN}"
  privateKey:
    rotationPolicy: Always
EOF
kubectl wait --for=condition=Ready certificate/dp-gateway-tls -n "${DATA_PLANE_NS}" --timeout=600s

# httpPort/httpsPort must be overridden: values-dp.yaml comes from the k3d
# layout where every plane shares one load balancer and the data plane is pinned
# to 19080/19443. Here each plane has its own LB, and every URL the guide
# publishes assumes 80/443.
helm upgrade --install --server-side=false openchoreo-data-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-data-plane \
  --version "${OPENCHOREO_VERSION}" \
  --namespace "${DATA_PLANE_NS}" \
  --create-namespace \
  --set clusterAgent.tls.generateCerts=true \
  --set gateway.tls.enabled=true \
  --set "gateway.tls.hostname=*.${AGENTS_DOMAIN}" \
  --set "gateway.tls.certificateRefs[0].name=dp-gateway-tls" \
  --set gateway.httpPort=80 \
  --set gateway.httpsPort=443 \
  --values "https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}/deployments/single-cluster/values-dp.yaml"

kubectl wait --for=condition=Available deployment --all -n "${DATA_PLANE_NS}" --timeout=600s

ports="$(kubectl get svc gateway-default -n "${DATA_PLANE_NS}" -o jsonpath='{.spec.ports[*].port}')"
[[ "$ports" == *"80"* && "$ports" == *"443"* ]] \
  || die "data-plane gateway is serving ports '${ports}', expected 80 and 443"

register_plane ClusterDataPlane "${DATA_PLANE_NS}" "  gateway:
    ingress:
      external:
        name: gateway-default
        namespace: ${DATA_PLANE_NS}
        http:
          host: \"${AGENTS_DOMAIN}\"
          listenerName: http
          port: 80
        https:
          host: \"${AGENTS_DOMAIN}\"
          listenerName: https
          port: 443
  secretStoreRef:
    name: default"

# ============================================================ Step 7: workflow plane

log "Step 7: workflow plane"
copy_gateway_ca "${BUILD_CI_NS}"
helm upgrade --install --server-side=false openchoreo-workflow-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-workflow-plane \
  --version "${OPENCHOREO_VERSION}" \
  --namespace "${BUILD_CI_NS}" \
  --create-namespace \
  --set clusterAgent.tls.generateCerts=true \
  --timeout 600s
kubectl wait --for=condition=Available deployment --all -n "${BUILD_CI_NS}" --timeout=600s
register_plane ClusterWorkflowPlane "${BUILD_CI_NS}" "  secretStoreRef:
    name: default"

# ============================================================ Step 8: observability

log "Step 8: observability plane"
copy_gateway_ca "${OBSERVABILITY_NS}"

kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: opensearch-admin-credentials
  namespace: openchoreo-observability-plane
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: default
  target:
    name: opensearch-admin-credentials
  data:
  - secretKey: username
    remoteRef: {key: opensearch-username, property: value}
  - secretKey: password
    remoteRef: {key: opensearch-password, property: value}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: observer-secret
  namespace: openchoreo-observability-plane
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: default
  target:
    name: observer-secret
  data:
  - secretKey: OPENSEARCH_USERNAME
    remoteRef: {key: opensearch-username, property: value}
  - secretKey: OPENSEARCH_PASSWORD
    remoteRef: {key: opensearch-password, property: value}
  - secretKey: UID_RESOLVER_OAUTH_CLIENT_SECRET
    remoteRef: {key: observer-oauth-client-secret, property: value}
EOF

kubectl wait -n "${OBSERVABILITY_NS}" --for=condition=Ready \
  externalsecret/opensearch-admin-credentials externalsecret/observer-secret --timeout=120s

kubectl apply -n "${OBSERVABILITY_NS}" \
  -f "https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}/deployments/values/oc-collector-configmap.yaml"

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: obs-gateway-tls
  namespace: ${OBSERVABILITY_NS}
spec:
  secretName: obs-gateway-tls
  issuerRef:
    name: openchoreo-ca
    kind: ClusterIssuer
  dnsNames:
    - "*.${BASE_DOMAIN}"
    - "${BASE_DOMAIN}"
  privateKey:
    rotationPolicy: Always
EOF
kubectl wait --for=condition=Ready certificate/obs-gateway-tls -n "${OBSERVABILITY_NS}" --timeout=600s

helm upgrade --install --server-side=false openchoreo-observability-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-observability-plane \
  --version "${OPENCHOREO_VERSION}" \
  --namespace "${OBSERVABILITY_NS}" \
  --create-namespace \
  --set gateway.tls.enabled=true \
  --set "gateway.tls.hostname=*.${BASE_DOMAIN}" \
  --set "gateway.tls.certificateRefs[0].name=obs-gateway-tls" \
  --set clusterAgent.tls.generateCerts=true \
  --set gateway.httpPort=80 \
  --set gateway.httpsPort=443 \
  --set observer.controlPlaneApiUrl="${OPENCHOREO_API_URL}" \
  --set observer.extraEnv.AUTH_SERVER_BASE_URL="${THUNDER_PUBLIC_URL}" \
  --set security.oidc.jwksUrl="${THUNDER_INTERNAL_URL}/oauth2/jwks" \
  --set security.oidc.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
  --values "https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}/deployments/single-cluster/values-op.yaml" \
  --timeout 25m

kubectl wait --for=condition=Available deployment --all -n "${OBSERVABILITY_NS}" --timeout=900s
for sts in $(kubectl get statefulset -n "${OBSERVABILITY_NS}" -o name 2>/dev/null); do
  kubectl rollout status "${sts}" -n "${OBSERVABILITY_NS}" --timeout=900s
done

ports="$(kubectl get svc gateway-default -n "${OBSERVABILITY_NS}" -o jsonpath='{.spec.ports[*].port}')"
[[ "$ports" == *"80"* && "$ports" == *"443"* ]] \
  || die "observability gateway is serving ports '${ports}', expected 80 and 443"

patch_entitlement_claim observer-auth-config "${OBSERVABILITY_NS}"
kubectl rollout restart deployment/observer -n "${OBSERVABILITY_NS}"
kubectl rollout status deployment/observer -n "${OBSERVABILITY_NS}" --timeout=180s

log "Step 8: observability modules"
# OPENSEARCH_INITIAL_ADMIN_PASSWORD must match the value seeded into OpenBao, or
# OpenSearch keeps the chart default while every client uses the generated one.
# Note the capital S in openSearch — it is the subchart alias.
helm upgrade --install --server-side=false observability-logs-opensearch \
  oci://ghcr.io/openchoreo/helm-charts/observability-logs-opensearch \
  --create-namespace --namespace "${OBSERVABILITY_NS}" --version "${OBS_LOGS_OPENSEARCH_VERSION}" \
  --set openSearchSetup.openSearchSecretName="opensearch-admin-credentials" \
  --set adapter.openSearchSecretName="opensearch-admin-credentials" \
  --set "openSearch.persistence.size=${OPENSEARCH_PV_SIZE}" \
  --set-string "openSearch.extraEnvs[0].name=OPENSEARCH_INITIAL_ADMIN_PASSWORD" \
  --set-string "openSearch.extraEnvs[0].value=${OPENSEARCH_PASSWORD}" \
  --timeout 10m

helm upgrade observability-logs-opensearch \
  oci://ghcr.io/openchoreo/helm-charts/observability-logs-opensearch \
  --namespace "${OBSERVABILITY_NS}" --version "${OBS_LOGS_OPENSEARCH_VERSION}" \
  --reuse-values --set fluent-bit.enabled=true --timeout 10m

helm upgrade --install --server-side=false observability-metrics-prometheus \
  oci://ghcr.io/openchoreo/helm-charts/observability-metrics-prometheus \
  --create-namespace --namespace "${OBSERVABILITY_NS}" --version "${OBS_METRICS_PROMETHEUS_VERSION}" --timeout 10m

helm upgrade --install --server-side=false observability-traces-opensearch \
  oci://ghcr.io/openchoreo/helm-charts/observability-tracing-opensearch \
  --create-namespace --namespace "${OBSERVABILITY_NS}" --version "${OBS_TRACING_OPENSEARCH_VERSION}" \
  --set openSearch.enabled=false \
  --set openSearchSetup.openSearchSecretName="opensearch-admin-credentials" \
  --set opentelemetry-collector.configMap.existingName="amp-opentelemetry-collector-config" \
  --timeout 10m

log "Step 8: registering the observability plane and linking the others to it"
OP_CA="$(kubectl get secret cluster-agent-tls -n "${OBSERVABILITY_NS}" -o jsonpath='{.data.ca\.crt}' | base64 -d)"
kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterObservabilityPlane
metadata:
  name: default
spec:
  planeID: default
  clusterAgent:
    clientCA:
      value: |
$(echo "$OP_CA" | sed 's/^/        /')
  observerURL: http://observer.${OBSERVABILITY_NS}.svc.cluster.local:8080
EOF

kubectl patch clusterdataplane default -n default --type merge \
  -p '{"spec":{"observabilityPlaneRef":{"kind":"ClusterObservabilityPlane","name":"default"}}}'
kubectl patch clusterworkflowplane default -n default --type merge \
  -p '{"spec":{"observabilityPlaneRef":{"kind":"ClusterObservabilityPlane","name":"default"}}}'

# ============================================================ Step 9-10

log "Step 9: plane status"
for ns in "${CONTROL_PLANE_NS}" "${DATA_PLANE_NS}" "${BUILD_CI_NS}" "${OBSERVABILITY_NS}" "${THUNDER_NS}"; do
  echo "--- ${ns} ---"
  kubectl get pods -n "$ns" --no-headers | grep -vE 'Running|Completed' || echo "  all Running/Completed"
done
kubectl get clusterdataplane,clusterworkflowplane,clusterobservabilityplane

log "Step 10: publishing DNS records"
CP_LB="$(gateway_address "${CONTROL_PLANE_NS}")"
DP_LB="$(gateway_address "${DATA_PLANE_NS}")"
OBS_LB="$(gateway_address "${OBSERVABILITY_NS}")"
printf '  control-plane   %s\n  data-plane      %s\n  observability   %s\n' "$CP_LB" "$DP_LB" "$OBS_LB"

for host in "${CONSOLE_PUBLIC_HOST}" "${API_PUBLIC_HOST}" "${THUNDER_PUBLIC_HOST}" "${CP_GW_PUBLIC_HOST}"; do
  upsert_dns "${host}" "${CP_LB}" CNAME
done
# This wildcard is required, not one of two possible layouts: rc1's env-Thunder
# hostnames are <handle>.${BASE_DOMAIN}, minted per environment after install,
# so they cannot be published up front. The four explicit records above stay —
# they document intent, and the RFC 4592 empty-non-terminal hazard that made
# them load-bearing disappeared along with the nested *.thunder wildcard. traces
# and agents keep their own records below and still win over this one, since an
# exact name always beats a wildcard.
upsert_dns "*.${BASE_DOMAIN}"         "${CP_LB}"  CNAME
upsert_dns "${OBS_API_PUBLIC_HOST}"   "${OBS_LB}" CNAME
upsert_dns "${AGENTS_DOMAIN}"         "${DP_LB}"  CNAME
upsert_dns "*.${AGENTS_DOMAIN}"       "${DP_LB}"  CNAME

log "Waiting for DNS to resolve"
# Two rules here, both learned the hard way:
#
# 1. Query a public resolver explicitly (§10). A bare `dig +short` goes to this
#    machine's stub resolver, and the first query for a name that Route 53 has
#    not published yet gets NXDOMAIN cached for the zone's negative TTL (900s).
#    That poisons *this machine* for the next 15 minutes — which is what 04 uses
#    to reach ${THUNDER_PUBLIC_URL} for am_token(), so 03 passing here used to be
#    followed by 04 failing to resolve a host that resolves fine everywhere else.
# 2. Fail loudly. The old loop `break`-ed on success and simply fell through on
#    exhaustion, so a name that never resolved printed nothing and still exited 0.
for host in "${THUNDER_PUBLIC_HOST}" "${OBS_API_PUBLIC_HOST}" "test.${AGENTS_DOMAIN}"; do
  resolved=false
  for _ in $(seq 1 30); do
    if [[ -n "$(dig +short @1.1.1.1 "$host")" ]]; then
      echo "  ${host} resolves"
      resolved=true
      break
    fi
    sleep 10
  done
  [[ "$resolved" == true ]] || die "${host} never resolved after 5 minutes — check the Route 53 records in ${ROUTE53_ZONE_ID}"
done

# Warm the local stub resolver too, and report rather than fail: an entry cached
# NXDOMAIN before publication expires on its own, but 04 cannot proceed until it
# does, so surfacing it here beats a confusing failure two scripts later.
for host in "${THUNDER_PUBLIC_HOST}" "${API_PUBLIC_HOST}" "${CONSOLE_PUBLIC_HOST}"; do
  if ! getent hosts "$host" >/dev/null 2>&1; then
    warn "${host} resolves publicly but not through this machine's resolver."
    warn "A negative answer is cached locally; it clears within the zone's 900s"
    warn "negative TTL. Run 'resolvectl flush-caches' to clear it immediately."
  fi
done

log "Phase 1 complete. Next: ./035-registry.sh then ./04-agent-manager.sh"
