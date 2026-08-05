#!/usr/bin/env bash
# Creates the EKS cluster with Cilium as the CNI and service proxy.
#
# Cilium has to be installed between the control plane and the nodes: with no
# CNI a node never reports Ready, so creating the cluster and its nodegroup in
# one shot would block until eksctl gave up and rolled back.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

for tool in eksctl aws kubectl helm; do
  command -v "$tool" >/dev/null || die "$tool not found on PATH"
done

if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  warn "Cluster ${CLUSTER_NAME} already exists — skipping creation, continuing with the rest."
else
  log "Creating EKS control plane (~15 min)"
  # cluster.yaml holds no nodegroup: eksctl rejects a disableDefaultAddons
  # cluster-create config that contains one. Nodes come from nodegroup.yaml
  # after Cilium is in place.
  eksctl create cluster -f "${SCRIPT_DIR}/cluster.yaml"
fi

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

if helm status cilium -n kube-system >/dev/null 2>&1; then
  warn "Cilium already installed — skipping."
else
  log "Installing Cilium ${CILIUM_VERSION} before any node joins"
  API_HOST="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.endpoint' --output text | sed 's#^https://##')"

  helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null

  # Pods stay Pending until nodes exist. cilium-operator tolerates every taint,
  # so it schedules onto the not-yet-Ready nodes the next step creates.
  helm install cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    -f "${SCRIPT_DIR}/cilium-values.yaml" \
    --set k8sServiceHost="${API_HOST}"
fi

if aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name ng-default \
     --region "${AWS_REGION}" >/dev/null 2>&1; then
  warn "Nodegroup ng-default already exists — skipping."
else
  log "Creating the nodegroup"
  eksctl create nodegroup -f "${SCRIPT_DIR}/nodegroup.yaml"
fi

log "Waiting for Cilium to program the nodes"
kubectl -n kube-system rollout status ds/cilium --timeout=10m
kubectl wait --for=condition=Ready node --all --timeout=10m

log "Node facts — OpenChoreo needs kernel 6.3+ and containerd 2.0+ for agent builds"
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
KERNEL:.status.nodeInfo.kernelVersion,\
RUNTIME:.status.nodeInfo.containerRuntimeVersion,\
KUBELET:.status.nodeInfo.kubeletVersion

kernel="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}')"
kernel_major_minor="$(echo "$kernel" | cut -d. -f1,2)"
if awk "BEGIN{exit !(${kernel_major_minor} < 6.3)}"; then
  warn "Kernel ${kernel} is below 6.3. User-namespaced agent builds will fail."
  warn "Install the Platform Resources chart with buildWorkflows.userNamespaces=false,"
  warn "or switch the nodegroup to an AMI with a newer kernel."
fi

log "Installing addons that Cilium does not cover"
eksctl create addon -f "${SCRIPT_DIR}/addons.yaml"

log "Making gp3 the default StorageClass"
# EKS ships a gp2 class bound to the removed in-tree provisioner; it would
# accept PVCs and never bind them.
kubectl apply -f "${SCRIPT_DIR}/storageclass-gp3.yaml"
kubectl annotate sc gp2 storageclass.kubernetes.io/is-default-class=false --overwrite 2>/dev/null || true
kubectl get sc

log "Verifying LoadBalancer provisioning"
kubectl create deploy lbtest --image=public.ecr.aws/nginx/nginx:stable
kubectl expose deploy lbtest --port=80 --type=LoadBalancer
if ! kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
     svc/lbtest --timeout=5m; then
  kubectl delete svc/lbtest deploy/lbtest --ignore-not-found
  die "LoadBalancer Service never got an address. The platform needs three of these."
fi
kubectl get svc lbtest
kubectl delete svc/lbtest deploy/lbtest

log "Cluster ready. Next: ./02-rds.sh"
