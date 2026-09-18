# gVisor isolation tier on EKS — design

Adds the **Sandboxing T2 (gVisor)** isolation tier to this install, following
[Isolation Tiers → gVisor](https://wso2.github.io/agent-manager/docs/v1.0.0/guides/isolation-tiers/gvisor/).
Agents in a gVisor environment run under the `runsc` runtime handler on a
dedicated node; the `default` environment stays on runc and nothing about the
existing platform install changes.

This is additive. It runs against a cluster already built by `00`→`04` and is
not part of that first-install path.

## Why gVisor and not Kata

Kata was the first choice and was abandoned on cost. Kata boots a real VM per
agent pod, so the node must expose `/dev/kvm`, and AWS offers hardware
virtualization only on `*.metal` instances — there is no nested virtualization
on Nitro. The cheapest x86 bare-metal instance in `us-east-1` is `c5n.metal` at
**$3.89/hr**, against a whole-cluster cost of $1.25–1.45/hr today. gVisor's
`systrap` platform intercepts syscalls in userspace, needs no KVM, and runs on
the same `c8i-flex` family as the rest of the cluster for **+$0.356/hr**.

The Kata research is kept here because it is a real fork in the road: if the
tier ever changes to Kata, a bare-metal nodegroup is mandatory, and Cilium then
also needs `socketLB.hostNamespaceOnly=true` — sockets inside a VM are not host
sockets, so socket-level load balancing silently strands service traffic. That
flag is **not** needed for gVisor and is deliberately not set (see *Unchanged*).

## Decisions

| Decision | Choice |
|---|---|
| Isolation tier | gVisor (`runsc`), RuntimeClass `gvisor` |
| Node | 1 × `c8i-flex.2xlarge`, dedicated nodegroup `ng-gvisor` |
| Node install path | `preBootstrapCommands`, before containerd's first start |
| runsc version | Pinned, installed from a dated release tarball |
| `install-gvisor.sh` | Replaced, not invoked |
| Environment | New `gvisor` environment; `default` stays runc |
| Fluent Bit toleration | Chart value, not `kubectl patch` |
| Cilium | Untouched |

## Why `install-gvisor.sh` is not used

Two independent reasons. Either alone would be worked around; together they
leave the script contributing four lines of TOML.

### It cannot download what it needs

`install-gvisor.sh` downloads two binaries:

```
BASE="https://storage.googleapis.com/gvisor/releases/release/latest/${GVISOR_ARCH}"
for bin in runsc containerd-shim-runsc-v1; do
    curl -fsSL --retry 3 "${BASE}/${bin}" -o "${GVISOR_TMP}/${bin}"
```

All four of those paths (`runsc`, `containerd-shim-runsc-v1`, and both
`.sha512` files) return **404** as of 2026-09-18. gVisor stopped publishing
loose binaries between the `20260817` and `20260831` releases; `latest/` and
every release from `20260831` on hold only `gvisor.tar.zstd` and
`gvisor.tar.bz2`. The script's first `curl -fsSL` fails and `set -euo pipefail`
aborts it.

Verified by listing the bucket:

| Release | `x86_64/` contents |
|---|---|
| `20260810` | `runsc`, `containerd-shim-runsc-v1`, `runsc-metric-server`, `gvisor.tar.bz2` |
| `20260817` | same |
| `20260831` | `gvisor.tar.bz2`, `gvisor.tar.zstd` |
| `20260907` | `gvisor.tar.bz2`, `gvisor.tar.zstd` |
| `20260914` | `gvisor.tar.bz2`, `gvisor.tar.zstd` |
| `latest` | `gvisor.tar.bz2`, `gvisor.tar.zstd` |

The repackaging matters more than the 404. From `20260831` on, gVisor ships the
sentry as **sidecar binaries** in a `gvisor-bin/` directory that must sit next
to `runsc`:

```
runsc
containerd-shim-runsc-v1
gvisor-bin/{gvisor_sentry,checkpointgofer,gvisor-sentry-prewarmer,runsc-fd-parking,runsc-metric-server}
```

`runsc flags` on `release-20260914.0` documents what happens without them:

- `-sidecar-usage-policy`: `STRICT` (sidecars must exist) or
  `LEGACY_DEPRECATED_SLOW_EMBEDDED_FALLBACK` — *"use embedded fallbacks if
  sidecars are missing; **will stop working after 2026-10**"*
- a download policy that fetches the missing sidecars into `gvisor-bin/` at
  sandbox start, described in-binary as *"This flag will go away in a few
  weeks!"*

So installing only the two binaries — what the upstream script does, and all
the `20260817` release offers — buys a runtime that either pulls ~100 MB per
cold start or leans on a fallback with a published expiry next month.

So the node bootstrap installs the full tarball for a pinned dated release into
`/usr/local/bin` itself.

### Its containerd precondition cannot be met in the install window

```bash
if ! systemctl is-active containerd &>/dev/null; then
    echo "❌ containerd service is not running."
    exit 1
fi
```

On AL2023 that is false at the only point this repo can run the install.
nodeadm is two units:

| Unit | Ordering | What it does |
|---|---|---|
| `nodeadm-boot-hook.service` | `Before=nodeadm-config.service` | OS networking expectations |
| `nodeadm-config.service` | `Before=cloud-init.service` | `nodeadm init --skip run` — **writes** `/etc/containerd/config.toml` |
| *cloud-init → cloud-final* | | **`preBootstrapCommands` run here** |
| `nodeadm-run.service` | `After=nodeadm-config.service cloud-final.service` | `nodeadm init --skip config` — **starts** containerd and kubelet |

`nodeadm-config.service` carries the comment *"run before cloud-init, then user
can still execute their own workflows from ec2 userdata cloud-init scripts"*,
and `nodeadm-run.service` *"start after cloud-init, in order to pickup changes
the user may have applied via cloud-init scripts"*. AL2023 deliberately opens
this window for modifying the generated config.

That is the ideal place to be, and it is why the upstream script cannot be
used: in this window the containerd config file already exists and containerd
has **not started yet**. The script would abort on its precondition.

Writing the runtime block directly is therefore both necessary and strictly
better than what the doc describes:

```toml
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
```

The plugin table name depends on the containerd **config version**, and getting
it wrong is silent — containerd ignores an unknown table and every runsc pod
then fails with `no runtime for "runsc" is configured`. Verified on the live
node (AL2023 `2023.12.20260909`, containerd `2.2.7`): nodeadm writes
`version = 3`, whose CRI runtime plugin is `io.containerd.cri.v1.runtime`.
Older AMIs wrote `version = 2` and `io.containerd.grpc.v1.cri`. The bootstrap
therefore reads the version out of the file and picks the table, rather than
assuming either. Upstream's `install-gvisor.sh` hardcodes the v2 name, so on
this AMI it would produce a silently dead runtime even with its download fixed.

## Why the node is born isolated

The doc is emphatic: *"Installing `runsc` reconfigures and restarts containerd,
which must never be done on a node serving live workloads,"* and prescribes
`kubectl cordon` / `kubectl drain` if the node is not empty.

Here that hazard does not exist rather than being mitigated. The runtime block
is appended **before containerd ever starts**, so nothing is reconfigured and
nothing is restarted — `nodeadm-run.service` brings containerd up with runsc
already registered. Belt and braces on top: eksctl passes a nodegroup's
`labels` and `taints` through to kubelet registration, so the node arrives
already carrying `gvisor=true` and `gvisor=true:NoSchedule` and nothing but
DaemonSets can ever land on it. There is no cordon/drain step and no window in
which a platform pod could schedule onto a node whose runtime is about to
change.

## Changes by file

### `env.sh`

```bash
export GVISOR_RELEASE="20260914"       # dated gVisor release, pinned
export GVISOR_NODEGROUP="ng-gvisor"
export GVISOR_RUNTIME_CLASS="gvisor"
export GVISOR_NETWORK_HOST="true"      # host netns stack; netstack measured broken here
```

`GVISOR_RELEASE` is pinned for the same reason every other component here is:
the upstream script's `release/latest` is both a moving target and currently a
404. `GVISOR_NETWORK_HOST` is read by `08-gvisor.sh` when it renders the
nodegroup config, so flipping it and recreating the nodegroup is the whole
remediation for a netstack failure.

### `nodegroup-gvisor.yaml` (new)

A separate eksctl `ClusterConfig` holding one managed nodegroup. Separate from
`nodegroup.yaml` for two reasons: `nodegroup.yaml` is applied during first
install while this is additive, and `eksctl create nodegroup -f` on a file
containing both would try to reconcile `ng-default` as well.

It is a **template**: the committed file carries named tokens for the pins, and
`08-gvisor.sh` renders it into `.secrets/nodegroup-gvisor.yaml` — the same
pattern `07-add-environment.sh` uses for `pipeline-values.json`. eksctl only
ever reads the rendered copy.

```yaml
managedNodeGroups:
  - name: ng-gvisor
    amiFamily: AmazonLinux2023
    instanceType: c8i-flex.2xlarge
    desiredCapacity: 1
    minSize: 0
    maxSize: 2
    volumeSize: 50
    volumeType: gp3
    volumeEncrypted: true
    privateNetworking: true
    maxPodsPerNode: 110
    labels:
      gvisor: "true"
    taints:
      - key: gvisor
        value: "true"
        effect: NoSchedule
      - key: node.cilium.io/agent-not-ready
        value: "true"
        effect: NoExecute
    iam:
      # identical to ng-default: worker, CNI, ECR read, SSM, plus the two
      # ec2 describes cilium-operator needs for ENI IPAM
```

Notes on the values that are not arbitrary:

- `maxPodsPerNode: 110` — same instance type as `ng-default`, so the same ENI
  budget applies: `c8i-flex.2xlarge` reports 4 interfaces at 30 IPv4 each, one
  per interface being the interface's own, giving 4 × 29 = 116 assignable.
  Cilium runs ENI IPAM with native routing, so this ceiling is hard.
- Both taints are needed. `gvisor=true:NoSchedule` is the tier's own, matched by
  the RuntimeClass's `scheduling.tolerations`. The Cilium `NoExecute` taint is
  what keeps pods off the node until `cilium-agent` is ready on it, exactly as
  on `ng-default`; Cilium removes it itself, which is why gVisor pods — whose
  toleration covers only the `gvisor` key — can land afterwards.
- `minSize: 0` so the node can be parked at $0 between sessions via
  `08-gvisor.sh scale 0`.
- AZ pinning needs no re-checking: `c8i-flex.2xlarge` is the type `cluster.yaml`
  already pinned `us-east-1a/b/c` around.

### `nodegroup-gvisor.yaml` → `preBootstrapCommands`

The install itself, as one bootstrap block:

```bash
set -euo pipefail
exec >>/var/log/install-gvisor.log 2>&1
echo "=== gVisor bootstrap $(date -Is) ==="

# nodeadm-config.service has already written this; the wait is for the case
# where a future AMI reorders the units, so the failure is a named one.
for _ in $(seq 1 30); do [ -f /etc/containerd/config.toml ] && break; sleep 2; done
[ -f /etc/containerd/config.toml ] || { echo "nodeadm never wrote containerd config"; exit 1; }

# The CRI plugin table was renamed between config versions and appending the
# wrong one is SILENT. Read the version, pick the table, reject anything else.
CFG=/etc/containerd/config.toml
ver="$(awk -F'=' '/^version[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${CFG}")"
case "${ver}" in
  3) PLUGIN="io.containerd.cri.v1.runtime" ;;   # AL2023 2023.12 / containerd 2.2
  2) PLUGIN="io.containerd.grpc.v1.cri"   ;;   # older AMIs
  *) echo "unexpected containerd config version: '${ver}'"; exit 1 ;;
esac

# tar --zstd shells out to zstd, which the AL2023 EKS AMI does not guarantee.
command -v zstd >/dev/null || dnf install -y -q zstd

# gvisor-bin/ must land next to runsc: releases from 20260831 on ship the
# sentry as separate sidecar binaries.
BASE="https://storage.googleapis.com/gvisor/releases/release/GVISOR_RELEASE/x86_64"
tmp="$(mktemp -d)"
curl -fsSL --retry 3 "${BASE}/gvisor.tar.zstd"        -o "${tmp}/gvisor.tar.zstd"
curl -fsSL --retry 3 "${BASE}/gvisor.tar.zstd.sha512" -o "${tmp}/gvisor.tar.zstd.sha512"
( cd "${tmp}" && sha512sum -c gvisor.tar.zstd.sha512 )
tar --zstd -xf "${tmp}/gvisor.tar.zstd" -C /usr/local/bin \
  runsc containerd-shim-runsc-v1 gvisor-bin
chmod 0755 /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1
rm -rf "${tmp}"
/usr/local/bin/runsc --version

# Register the runtime. containerd has not started yet, so this is a config
# edit, not a reconfiguration — nodeadm-run.service starts it with runsc
# already present. See "Why install-gvisor.sh is not used".
printf '\n# gVisor (runsc) runtime\n[plugins."%s".containerd.runtimes.runsc]\n  runtime_type = "io.containerd.runsc.v1"\n' "${PLUGIN}" >> "${CFG}"
```

When `GVISOR_NETWORK_HOST` is true, the block instead carries the options
sub-table and `/etc/containerd/runsc.toml` is written alongside it — the same
shape `install-gvisor.sh` uses for its host-network path:

```toml
  [plugins."<PLUGIN>".containerd.runtimes.runsc.options]
    TypeUrl = "io.containerd.runsc.v1.options"
    ConfigPath = "/etc/containerd/runsc.toml"
```

`GVISOR_RELEASE` and the network mode are substituted by `08-gvisor.sh` when it
renders this file, so the pins stay in `env.sh` with every other version here.
Substitution is by explicit allowlist — `sed` on named `@@TOKEN@@` markers,
never bare `envsubst`, which would eat `${tmp}`, `${BASE}` and every other shell
variable in the block. The containerd blocks are written with `printf` rather
than heredocs: the whole bootstrap is a YAML block scalar, and a heredoc
terminator indented to match its surrounding `if` would never close once YAML
strips the common indentation.

Three facts this relies on, all verified:

- `/usr/local/bin` is on systemd's default `PATH`, so containerd resolves
  `containerd-shim-runsc-v1` for `runtime_type = "io.containerd.runsc.v1"`
  without any unit override.
- EKS AL2023 `2023.12.20260909` writes `version = 3`, making
  `plugins."io.containerd.cri.v1.runtime"` the correct table — confirmed by
  reading `/etc/containerd/config.toml` off a running `ng-default` node over
  SSM, not from the nodeadm template. The bootstrap detects this rather than
  assuming it, and rejects any version it does not know.
- `preBootstrapCommands` was broken for AmazonLinux2023 (eksctl #7903) and
  fixed in #8031; this repo runs eksctl 0.229.0, well past it.

**A non-zero exit here does not fail the node.** `nodeadm-run.service` is
ordered `After=cloud-final.service`, which is satisfied whether cloud-init's
scripts succeeded or not, so a node whose bootstrap aborted still joins the
cluster and reports `Ready` — with no runsc on it. Gate 1 below is the real
check; the log is at `/var/log/install-gvisor.log`, and cloud-init's own
`/var/log/cloud-init-output.log` records that the part ran.

### `08-gvisor.sh` (new)

```
./08-gvisor.sh              install (default)
./08-gvisor.sh verify       re-run the gates only
./08-gvisor.sh scale <n>    park at 0 / bring back to n
./08-gvisor.sh uninstall    delete the nodegroup and the RuntimeClass
```

`uninstall` leaves the Fluent Bit toleration in place — it is harmless without
a tainted node, and reverting it would mean another chart upgrade.

Install, in order:

1. Tool and kubeconfig guards — `require_placeholders_filled`,
   `kubeconfig_points_at_cluster`, from `env.sh` like every other script.
2. Render `nodegroup-gvisor.yaml` into `.secrets/` with `GVISOR_RELEASE` and the
   `GVISOR_NETWORK_HOST` variant of the containerd block substituted.
3. Create the nodegroup if absent, guarded on `aws eks describe-nodegroup`
   exactly as `01-cluster.sh` guards `ng-default`. Re-runnable.
4. Wait for the node `Ready` and for `ds/cilium` to have programmed it.
5. Apply the RuntimeClass from the pinned tag —
   `amp/v${VERSION}/deployments/k8s/gvisor-runtimeclass.yaml` (confirmed
   present at `amp/v1.0.0`; the doc links `main`). It carries
   `scheduling.nodeSelector` and `scheduling.tolerations`, which is what lets
   the SandboxTemplate set nothing but `runtimeClassName`.
6. Give Fluent Bit the toleration — see below.
7. Run the three gates.
8. Print the exact `07-add-environment.sh` line to create the environment.

### Fluent Bit toleration — chart value, not a patch

The doc prescribes:

```bash
kubectl patch daemonset fluent-bit -n openchoreo-observability-plane --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"operator":"Exists"}]}]'
```

Here Fluent Bit is the `fluent-bit` subchart of
`observability-logs-opensearch`, which `03-openchoreo.sh:690` already enables
through a `--reuse-values` upgrade. A `kubectl patch` on a Helm-owned DaemonSet
is reverted by the next chart upgrade — the same trap the `DeploymentPipeline`
CR note in `07-add-environment.sh` describes. The durable form restates it as a
value:

```bash
helm upgrade observability-logs-opensearch \
  oci://ghcr.io/openchoreo/helm-charts/observability-logs-opensearch \
  --namespace "${OBSERVABILITY_NS}" --version "${OBS_LOGS_OPENSEARCH_VERSION}" \
  --reuse-values --set "fluent-bit.tolerations[0].operator=Exists"
```

Without it the DaemonSet skips the tainted node and agents in the gVisor
environment produce no logs, with nothing in the control plane naming the cause.
`prometheus-node-exporter` already tolerates every taint (`06-node-exporter.sh`),
and the Cilium and EBS CSI node DaemonSets tolerate all taints by default, so
Fluent Bit is the only one that needs this.

### `07-add-environment.sh`

Gains `--isolation-tier <gvisor|kata>`. Flags are parsed in any order after the
two positionals, so the existing `--production` keeps working.

Upstream's `add-environment.sh` establishes the contract this mirrors:
`isolationTier` is accepted **only on create**, and the field is omitted
entirely when no tier is set so runc environments send the same payload they
always did.

```bash
-d "$(jq -n --arg n "${ENV_NAME}" ... --arg tier "${ISOLATION_TIER}" '{
    name: $n, displayName: $d, dataplaneRef: "default", dnsPrefix: $n,
    isProduction: $prod,
    gateway: {ingress: {external: {http: {...}, https: {...}}}}
  } + (if $tier == "" then {} else {isolationTier: $tier} end)')"
```

Observed on 1.0.0: a successful create (HTTP 201) stores the tier as the
`openchoreo.dev/isolation-tier` **annotation** on the Environment rather than in
its spec — `spec.isolationTier` is absent afterwards. So the annotation is the
canonical representation, not merely a fallback, and the `409` path below writes
exactly what the API would have written itself:

```bash
kubectl annotate environment "${ENV_NAME}" -n "${DEFAULT_NS}" \
  "openchoreo.dev/isolation-tier=${ISOLATION_TIER}" --overwrite
```

It also pre-flights the tier: with `--isolation-tier gvisor` it dies early if
`kubectl get runtimeclass gvisor` finds nothing, naming `./08-gvisor.sh`. An
environment created against a missing RuntimeClass leaves every agent Pending
with nothing explaining why, and environments here are provision-once.

The environment is then:

```bash
./07-add-environment.sh gvisor "gVisor Sandbox" --isolation-tier gvisor
```

`gvisor` is 6 characters, inside the 8-character cap that split topology
imposes on org `default`.

### `README.md`

- `08-gvisor.sh` row in the order table, marked additive rather than part of
  `00`→`04`.
- Cluster shape: the fourth node, why it is dedicated and tainted.
- Cost: +$0.356/hr while the node is up, and that `scale 0` parks it.
- Deliberate deviations: `install-gvisor.sh` replaced rather than run (the 404,
  the sidecar split, and its unmeetable containerd precondition), Fluent Bit as
  a chart value, and a declarative `preBootstrapCommands` install in place of
  the doc's manual on-node `curl | sudo bash`.

### `TROUBLESHOOTING.md`

Three new entries, in the established symptom → cause → fix shape:

- `install-gvisor.sh` aborts on its first `curl` — `release/latest` no longer
  publishes loose binaries.
- Agent cold starts stall or pull ~100 MB — `gvisor-bin/` sidecars missing next
  to `runsc`; the embedded fallback expires after 2026-10.
- Agents run but have no traces, metrics or DNS — gVisor's netstack and
  cross-node Service traffic; `GVISOR_NETWORK_HOST=true` and recreate the
  nodegroup.

### `99-teardown.sh`

No change. It enumerates nodegroups dynamically
(`aws eks list-nodegroups` → loop) and already deletes whatever it finds, so
`ng-gvisor` is covered.

## Unchanged

- **Cilium.** `socketLB.hostNamespaceOnly=true` is Cilium's documented
  requirement for *Kata* with kube-proxy replacement, because sockets inside
  the VM are not host sockets and socket-level load balancing never sees them.
  gVisor's netstack does not use host sockets either, so the socket hooks never
  fire and tc-based service translation applies regardless — the flag changes
  nothing here. Cilium's Kata guide also warns about a route-MTU mismatch, which
  is an overlay artifact; this cluster runs native routing with real VPC pod
  addresses and no encapsulation.
- **The `default` environment** stays on runc, along with every platform
  component. Isolation tier is per-environment.
- **`03`, `04`, `05`, `06`** and the first-install path.
- **Node count and shape of `ng-default`.** The gVisor node is additional, not a
  replacement; `ng-default`'s three nodes are sized for the platform and the
  README already records that 4 vCPU left it CPU-bound.

## Execution — staged, with gates

| Stage | Command | Gate |
|---|---|---|
| 1 | `./08-gvisor.sh` | node `Ready`, `kubectl get runtimeclass gvisor` |
| 2 | gate 1 (automatic) | a `runtimeClassName: gvisor` pod shows the gVisor banner in `dmesg` |
| 3 | gate 2 (automatic) | that pod landed on the `gvisor=true` node |
| 4 | gate 3 (automatic) | `nslookup kubernetes.default` resolves from inside a gVisor pod |
| 5 | `./07-add-environment.sh gvisor "gVisor Sandbox" --isolation-tier gvisor` | gateways `Programmed`, environment listed with its tier |
| 6 | deploy an agent, promote it to `gvisor` | `.spec.runtimeClassName` is `gvisor`; traces and logs arrive |

The three gates in stage 2–4 are what separate "the install script exited 0"
from "the tier works", and each fails for a different reason:

- **Gate 1** is the only real proof the containerd wiring took, because a failed
  bootstrap still yields a `Ready` node. Whatever went wrong — the tarball
  download, an unknown config version, an append into the wrong plugin table — the
  pod fails with `no runtime for "runsc" is configured`, and this is where it
  surfaces.
- **Gate 2** proves the RuntimeClass's `scheduling` block is doing its job.
- **Gate 3** is the doc's own `nc-runsc` test and the one open risk below.

## Open items

- **Gate 3 is settled: the netstack does not work here, and the default is now
  `true`.** Measured on the built cluster, not predicted. A netstack sandbox
  reached other pods by IP across nodes over both TCP and UDP, but every Service
  ClusterIP timed out, while a runc pod on the same node was fine.
  `cilium monitor` on the sandbox node showed why:

  ```
  -> network flow 0x0, identity 21339->world state new ifindex enp39s0
     orig-ip 0.0.0.0: 10.0.158.2:27242 -> 172.20.0.10:53 udp
  ```

  The packet reaches `to-netdev` with the ClusterIP **still intact** and is
  forwarded out the uplink as `world` traffic. gVisor's netstack never traverses
  Cilium's `from-container` program, so nothing DNATs it. The same query from a
  runc pod produces no datapath trace at all — it is translated before the
  datapath.

  This also corrects the *Unchanged → Cilium* reasoning below: that section
  argued tc-based translation "applies regardless". It does not apply to gVisor.
  `socketLB.hostNamespaceOnly=true` is still not the fix, but for a different
  reason than stated — socketLB is already disabled on this cluster
  (`bpf-lb-sock: false`), so the flag is inert. No Cilium setting fixes this;
  host networking does. See TROUBLESHOOTING §38.
- **`-sidecar-usage-policy=STRICT` is not set.** With the sidecars installed the
  default policy uses them and nothing downloads, so STRICT would only turn a
  broken install from slow into loud. It is also a flag gVisor describes as
  temporary, and an unknown flag in `runsc.toml` fails every sandbox — so
  hardcoding it trades a quiet failure for a total one on the next release
  bump. Add it only while chasing a sidecar problem.
- **`20260817` is the escape hatch** if the tarball path gives trouble: the last
  release with loose binaries, and a pre-split self-contained `runsc` that needs
  no sidecars. It is a frozen old build, which is why it is the fallback and not
  the choice.
- **runsc has no upgrade story here.** Bumping `GVISOR_RELEASE` needs a node
  recycle, since the version is baked into the launch template. Acceptable for a
  single-node tier; worth revisiting if the tier grows.

## Out of scope

- Kata. Documented above as the rejected alternative and what it would cost.
- GKE's built-in `--sandbox type=gvisor`, which is the doc's other path and has
  no EKS equivalent.
- Moving the `default` environment onto a sandboxed tier.
- Autoscaling the gVisor nodegroup beyond `maxSize: 2`, and warm-pool sizing for
  gVisor environments.
- `kubectl port-forward` into gVisor pods, which gVisor does not support; use
  the gateway endpoints, as with Kata.
