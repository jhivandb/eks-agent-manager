#!/usr/bin/env bash
# Container registry for build workflows, at registry.${BASE_DOMAIN}.
#
# Why not ECR: publish-image.yaml pushes ${workflowRunName}-image, a new
# repository name on every build run, and ECR has no push-to-create. It also
# mounts a static .dockerconfigjson, so ECR's 12-hour token would go stale. The
# CNCF distribution registry creates repositories on push.
#
# Runs with TLS but no authentication, behind an INTERNAL load balancer, so it is
# reachable only from inside the VPC. That keeps two things simple: the workflow
# pushes without an authfile (its push-secret volume is declared optional), and
# containerd pulls agent images without a pull secret in every dp-* namespace.
# The tradeoff is that anything already inside the VPC can push and pull.
# Put htpasswd auth in front of it before this carries anything real.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

require_placeholders_filled
kubeconfig_points_at_cluster

REGISTRY_IMAGE="public.ecr.aws/docker/library/registry:2"
REGISTRY_PV_SIZE="${REGISTRY_PV_SIZE:-50Gi}"

log "Creating namespace ${REGISTRY_NS}"
kubectl create namespace "${REGISTRY_NS}" --dry-run=client -o yaml | kubectl apply -f -

log "Issuing a certificate for ${REGISTRY_HOST}"
# DNS-01 does not need the host to be reachable, so this resolves before the
# load balancer below exists.
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: registry-tls
  namespace: ${REGISTRY_NS}
spec:
  secretName: registry-tls
  issuerRef:
    name: openchoreo-ca
    kind: ClusterIssuer
  dnsNames:
    - "${REGISTRY_HOST}"
  privateKey:
    rotationPolicy: Always
EOF
kubectl wait --for=condition=Ready certificate/registry-tls -n "${REGISTRY_NS}" --timeout=600s

log "Deploying the registry"
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-data
  namespace: ${REGISTRY_NS}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: ${REGISTRY_PV_SIZE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: ${REGISTRY_NS}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels: {app: registry}
  template:
    metadata:
      labels: {app: registry}
    spec:
      containers:
        - name: registry
          image: ${REGISTRY_IMAGE}
          ports:
            - containerPort: 5000
          env:
            - name: REGISTRY_HTTP_ADDR
              value: "0.0.0.0:5000"
            - name: REGISTRY_HTTP_TLS_CERTIFICATE
              value: /certs/tls.crt
            - name: REGISTRY_HTTP_TLS_KEY
              value: /certs/tls.key
            - name: REGISTRY_STORAGE_DELETE_ENABLED
              value: "true"
          volumeMounts:
            - {name: certs, mountPath: /certs, readOnly: true}
            - {name: data,  mountPath: /var/lib/registry}
          readinessProbe:
            httpGet: {path: /v2/, port: 5000, scheme: HTTPS}
            initialDelaySeconds: 5
          resources:
            requests: {cpu: 100m, memory: 256Mi}
            limits:   {memory: 1Gi}
      volumes:
        - name: certs
          secret: {secretName: registry-tls}
        - name: data
          persistentVolumeClaim: {claimName: registry-data}
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: ${REGISTRY_NS}
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-internal: "true"
spec:
  type: LoadBalancer
  selector: {app: registry}
  ports:
    - name: https
      port: 443
      targetPort: 5000
EOF

kubectl rollout status deployment/registry -n "${REGISTRY_NS}" --timeout=300s

log "Publishing the DNS record"
REGISTRY_LB="$(for _ in $(seq 1 60); do
  addr="$(kubectl get svc registry -n "${REGISTRY_NS}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$addr" ]] && { echo "$addr"; break; }
  sleep 10
done)"
[[ -n "${REGISTRY_LB}" ]] || die "registry Service never got a LoadBalancer address"
echo "  ${REGISTRY_HOST} -> ${REGISTRY_LB}"
upsert_dns "${REGISTRY_HOST}" "${REGISTRY_LB}" CNAME

log "Verifying the registry from inside the cluster"
# It resolves to a private address, so this has to run from a pod, not here.
kubectl delete pod registry-probe -n "${REGISTRY_NS}" --ignore-not-found >/dev/null 2>&1 || true
for attempt in $(seq 1 20); do
  if kubectl run registry-probe -n "${REGISTRY_NS}" --rm -i --restart=Never \
       --image=public.ecr.aws/docker/library/alpine:3 --quiet -- \
       sh -c "apk add --no-cache curl >/dev/null 2>&1 && curl -sf https://${REGISTRY_HOST}/v2/ -o /dev/null && echo OK" 2>/dev/null | grep -q OK; then
    echo "  registry answers /v2/ over verified TLS"
    break
  fi
  [[ $attempt -eq 20 ]] && die "registry unreachable at https://${REGISTRY_HOST}/v2/ — check DNS propagation and the internal LB"
  sleep 15
done

log "Registry ready at ${REGISTRY_ENDPOINT}. Next: ./04-agent-manager.sh"
