#!/usr/bin/env bash
# Sandboxing T2 (gVisor) isolation tier.
#
#   ./08-gvisor.sh              install (default)
#   ./08-gvisor.sh verify       re-run the gates only
#   ./08-gvisor.sh scale <n>    park the node at 0 / bring it back to n
#   ./08-gvisor.sh uninstall    delete the nodegroup and the RuntimeClass
#
# Additive: runs against a cluster already built by 00->04, and is not part of
# that first-install path. Agents in a gVisor environment run under the runsc
# runtime handler on a dedicated, tainted node; the default environment stays on
# runc and nothing about the existing platform install changes.
#
# This deliberately does NOT run upstream's deployments/setup/install-gvisor.sh.
# That script downloads release/latest/<arch>/runsc, which 404s (gVisor now ships
# only tarballs), installs two binaries where releases from 20260831 on also need
# the gvisor-bin/ sidecars, and aborts unless containerd is already running --
# which is false in the one window where this repo can install declaratively.
# The nodegroup's preBootstrapCommands do the whole job instead, before
# containerd's first start. See the design doc:
#   docs/superpowers/specs/2026-09-18-gvisor-isolation-tier-design.md

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

require_placeholders_filled
kubeconfig_points_at_cluster

TEMPLATE="${SCRIPT_DIR}/nodegroup-gvisor.yaml"
RENDERED="${SECRETS_DIR}/nodegroup-gvisor.yaml"
RUNTIME_CLASS_URL="https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}/deployments/k8s/gvisor-runtimeclass.yaml"
GATE_POD="gvisor-gate"
GATE_IMAGE="public.ecr.aws/docker/library/busybox:1.36"

# ------------------------------------------------------------------ subcommands

case "${1:-install}" in
  scale)
    N="${2:-}"
    [[ "${N}" =~ ^[0-9]+$ ]] || die "usage: $0 scale <n>"
    log "Scaling ${GVISOR_NODEGROUP} to ${N}"
    # --nodes-min too: scaling to 0 is rejected while minSize is above it, and
    # parking the node at $0 between sessions is the point of minSize 0.
    eksctl scale nodegroup --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" \
      --name "${GVISOR_NODEGROUP}" --nodes "${N}" --nodes-min "${N}"
    exit 0
    ;;
  uninstall)
    log "Deleting nodegroup ${GVISOR_NODEGROUP}"
    eksctl delete nodegroup --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" \
      --name "${GVISOR_NODEGROUP}" --wait 2>/dev/null || warn "nodegroup was not present"
    kubectl delete runtimeclass "${GVISOR_RUNTIME_CLASS}" --ignore-not-found
    kubectl delete pod "${GATE_POD}" --ignore-not-found >/dev/null 2>&1 || true
    # The Fluent Bit toleration stays. It is harmless with no tainted node, and
    # reverting it would mean another chart upgrade for nothing.
    log "Done. The Fluent Bit toleration was left in place."
    exit 0
    ;;
  install|verify) MODE="${1:-install}" ;;
  *) die "usage: $0 [install|verify|scale <n>|uninstall]" ;;
esac

[[ "${GVISOR_NETWORK_HOST}" == "true" || "${GVISOR_NETWORK_HOST}" == "false" ]] \
  || die "GVISOR_NETWORK_HOST must be 'true' or 'false', got '${GVISOR_NETWORK_HOST}'"

# ------------------------------------------------------------------- the gates

run_gates() {
  log "Gate pod: a runtimeClassName=${GVISOR_RUNTIME_CLASS} pod on the sandbox node"
  kubectl delete pod "${GATE_POD}" --ignore-not-found --wait=true >/dev/null 2>&1 || true

  # No nodeSelector and no tolerations here on purpose: the RuntimeClass carries
  # scheduling.nodeSelector and scheduling.tolerations, and the API server
  # injects both. That is what lets the SandboxTemplate set nothing but
  # runtimeClassName, and gate 2 is what proves the injection happened.
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${GATE_POD}
spec:
  runtimeClassName: ${GVISOR_RUNTIME_CLASS}
  restartPolicy: Never
  containers:
    - name: probe
      image: ${GATE_IMAGE}
      command: ["sleep", "600"]
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits:   {memory: 64Mi}
EOF

  if ! kubectl wait --for=condition=Ready "pod/${GATE_POD}" --timeout=5m; then
    echo "--- pod describe ---"
    kubectl describe "pod/${GATE_POD}" | tail -30
    die "gate pod never became Ready. 'no runtime for \"runsc\" is configured' here means the
bootstrap did not take: ssm into the node and read /var/log/install-gvisor.log.
A failed bootstrap still yields a Ready node, so this is the first place it shows."
  fi

  # Gate 1 -- the only real proof the containerd wiring took. gVisor's sentry
  # emits its own kernel banner; a runc container's dmesg would not mention it.
  log "Gate 1: the sandbox is really gVisor"
  local dmesg_out
  dmesg_out="$(kubectl exec "${GATE_POD}" -- dmesg 2>/dev/null | head -3 || true)"
  echo "${dmesg_out}"
  grep -qi 'gvisor' <<<"${dmesg_out}" \
    || die "gate 1 failed: no gVisor banner in dmesg. The pod started, but not under runsc."
  echo "  OK"

  # Gate 2 -- the RuntimeClass scheduling block did its job.
  log "Gate 2: it landed on the ${GVISOR_RUNTIME_CLASS} node"
  local node labelled
  node="$(kubectl get pod "${GATE_POD}" -o jsonpath='{.spec.nodeName}')"
  labelled="$(kubectl get node "${node}" -o jsonpath='{.metadata.labels.gvisor}' 2>/dev/null || true)"
  echo "  node=${node} gvisor=${labelled:-<unset>}"
  [[ "${labelled}" == "true" ]] \
    || die "gate 2 failed: pod ran on ${node}, which is not labelled gvisor=true."
  echo "  OK"

  # Gate 3 -- the open risk. gVisor's userspace netstack cannot always carry
  # cross-node Service and DNS traffic; DNS is the cheapest thing that exercises
  # both. Remediation is GVISOR_NETWORK_HOST=true plus a nodegroup recreate,
  # because the bootstrap lives in the launch template.
  # The FQDN, not the short name: busybox nslookup does not apply the search
  # domains from resolv.conf, so `kubernetes.default` returns NXDOMAIN even on a
  # perfectly healthy pod. Asking for the resolved name directly is the test.
  #
  # The exit status is the check, via command substitution rather than a pipe:
  # env.sh sets `set -o pipefail`, so `nslookup ... | grep` reports nslookup's
  # failure regardless of what grep matched -- and grepping for "Address" would
  # match the nameserver's own address line and pass on an NXDOMAIN anyway.
  #
  # This exercises the ClusterIP path, which is the thing that actually breaks:
  # the nameserver is the kube-dns Service VIP (see TROUBLESHOOTING §38).
  log "Gate 3: cluster DNS resolves from inside the sandbox"
  local dns_out
  if dns_out="$(kubectl exec "${GATE_POD}" -- nslookup kubernetes.default.svc.cluster.local 2>&1)"; then
    echo "${dns_out}" | grep -E 'Name:|Address' | tail -2
    echo "  OK (network=$([[ "${GVISOR_NETWORK_HOST}" == "true" ]] && echo host || echo netstack))"
  else
    echo "${dns_out}"
    kubectl delete pod "${GATE_POD}" --ignore-not-found >/dev/null 2>&1 || true
    if [[ "${GVISOR_NETWORK_HOST}" == "true" ]]; then
      die "gate 3 failed with GVISOR_NETWORK_HOST=true, which is already the fallback.
The sandbox is using the host network stack inside the pod netns, so this is not
the netstack limitation in TROUBLESHOOTING §38. Check that coredns is healthy and
that cilium has programmed the sandbox node."
    fi
    die "gate 3 failed: no DNS from inside a gVisor pod.
gVisor's userspace netstack does not traverse Cilium's from-container program, so
Service ClusterIPs are forwarded untranslated and time out (TROUBLESHOOTING §38).
Fix:
  1. set GVISOR_NETWORK_HOST=\"true\" in env.sh
  2. ./08-gvisor.sh uninstall && ./08-gvisor.sh
Syscall isolation is kept either way; only the pod's network stack changes."
  fi

  kubectl delete pod "${GATE_POD}" --ignore-not-found >/dev/null 2>&1 || true
  log "All three gates passed."
}

if [[ "${MODE}" == "verify" ]]; then
  run_gates
  exit 0
fi

# ---------------------------------------------------------------- 1. nodegroup

log "Rendering ${TEMPLATE##*/} (release ${GVISOR_RELEASE}, network_host=${GVISOR_NETWORK_HOST})"
mkdir -p "${SECRETS_DIR}"; chmod 700 "${SECRETS_DIR}"
# sed on named tokens, never envsubst: the bootstrap block is full of ${tmp},
# ${BASE} and friends that a bare envsubst would blank out.
sed -e "s/@@GVISOR_RELEASE@@/${GVISOR_RELEASE}/g" \
    -e "s/@@GVISOR_NETWORK_HOST@@/${GVISOR_NETWORK_HOST}/g" \
    "${TEMPLATE}" > "${RENDERED}"
grep -q '@@' "${RENDERED}" && die "unsubstituted token left in ${RENDERED}"

if aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
     --nodegroup-name "${GVISOR_NODEGROUP}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  warn "Nodegroup ${GVISOR_NODEGROUP} already exists — skipping creation."
  warn "Its bootstrap is baked into the launch template: to change GVISOR_RELEASE"
  warn "or GVISOR_NETWORK_HOST, run '$0 uninstall' first."
else
  log "Creating nodegroup ${GVISOR_NODEGROUP} (~5 min)"
  eksctl create nodegroup -f "${RENDERED}"
fi

log "Waiting for the sandbox node to register"
for _ in $(seq 1 60); do
  NODE="$(kubectl get nodes -l gvisor=true -o name 2>/dev/null | head -1)"
  [[ -n "${NODE}" ]] && break
  sleep 10
done
[[ -n "${NODE:-}" ]] || die "no node with label gvisor=true appeared"

kubectl wait --for=condition=Ready "${NODE}" --timeout=10m
# Cilium has to program the node before anything can schedule on it — it owns
# the node.cilium.io/agent-not-ready NoExecute taint and removes it itself.
log "Waiting for Cilium to program ${NODE}"
kubectl -n kube-system rollout status ds/cilium --timeout=10m

kubectl get nodes -l gvisor=true -o custom-columns=\
NAME:.metadata.name,\
KERNEL:.status.nodeInfo.kernelVersion,\
RUNTIME:.status.nodeInfo.containerRuntimeVersion

# ------------------------------------------------------------- 2. RuntimeClass

log "Applying the gvisor RuntimeClass from amp/v${VERSION}"
# The pinned tag, not main: the doc links main, but this file exists at the
# release tag and every other pin here is a tag.
kubectl apply -f "${RUNTIME_CLASS_URL}"
kubectl get runtimeclass "${GVISOR_RUNTIME_CLASS}"

# ---------------------------------------------------------------- 3. Fluent Bit

# The doc prescribes `kubectl patch daemonset fluent-bit ...`. Here Fluent Bit is
# the fluent-bit subchart of observability-logs-opensearch, which 03 installs, so
# a patch is reverted by the next chart upgrade and agent logs then stop arriving
# from the sandbox node with nothing naming the cause. State it as a value.
#
# node-exporter already tolerates every taint (06-node-exporter.sh), and the
# Cilium and EBS CSI node DaemonSets tolerate all taints by default, so Fluent
# Bit is the only DaemonSet that needs this.
if helm status observability-logs-opensearch -n "${OBSERVABILITY_NS}" >/dev/null 2>&1; then
  if kubectl get daemonset fluent-bit -n "${OBSERVABILITY_NS}" \
       -o jsonpath='{.spec.template.spec.tolerations}' 2>/dev/null | grep -q 'Exists'; then
    log "Fluent Bit already tolerates the sandbox taint — skipping."
  else
    log "Giving Fluent Bit a toleration for the ${GVISOR_RUNTIME_CLASS} taint"
    helm upgrade observability-logs-opensearch \
      "oci://ghcr.io/openchoreo/helm-charts/observability-logs-opensearch" \
      --namespace "${OBSERVABILITY_NS}" \
      --version "${OBS_LOGS_OPENSEARCH_VERSION}" \
      --reuse-values \
      --set "fluent-bit.tolerations[0].operator=Exists" \
      --timeout 10m
    kubectl rollout status daemonset/fluent-bit -n "${OBSERVABILITY_NS}" --timeout=5m
  fi
else
  warn "observability-logs-opensearch is not installed — skipping the Fluent Bit toleration."
  warn "Agents in the gVisor environment will produce no logs until 03-openchoreo.sh has run."
fi

# ------------------------------------------------------------------- 4. gates

run_gates

cat <<EOF

$(printf '\033[1;34m==> gVisor tier ready\033[0m')

Create the environment:

  ./07-add-environment.sh gvisor "gVisor Sandbox" --isolation-tier gvisor

Then promote an agent to it. Its pod should carry
.spec.runtimeClassName=${GVISOR_RUNTIME_CLASS} and land on the gvisor=true node.

Park the node at \$0 between sessions:  ./08-gvisor.sh scale 0
Bring it back:                          ./08-gvisor.sh scale 1
EOF
