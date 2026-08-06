# Agent Manager on EKS

Scripted install of WSO2 Agent Manager (the nightly pinned as `VERSION` in
`env.sh` — nightlies delete the previous day's images, so this moves daily) on
a fresh EKS cluster, following
`documentation/docs/getting-started/on-your-environment.mdx`
(the `next` docs) with production variants throughout.

**Run these with `bash`, not fish.** The install uses heredocs and `export`
semantics fish does not share.

Every failure hit (or dodged) during the first install is written up in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) — symptom, root cause, and the fix
now baked into the scripts.

## Order

| Script | What it does | Time |
|---|---|---|
| `00-domain.sh {check\|register\|adopt} <domain>` | Route 53 hosted zone; writes `domain.env` | ~10 min |
| `01-cluster.sh` | EKS 1.34, Cilium, addons, gp3 default StorageClass | ~25 min |
| `02-rds.sh` | RDS PostgreSQL 17.10, 4 databases, Thunder's schema | ~15 min |
| `03-openchoreo.sh` | Phase 1: prereqs, OpenBao, TLS, Thunder, 4 planes, DNS | ~40 min |
| `035-registry.sh` | Container registry at `registry.<base>` | ~5 min |
| `04-agent-manager.sh` | Phase 2: Agent Manager, extensions, env-Thunder | ~30 min |
| `05-access.sh {public\|vpn}` | Locks the public endpoints + EKS API to the VPN, or reopens them | ~5 min |
| `07-add-environment.sh <name> "<Display>" [--production]` | New environment: split gateways, env-Thunder, pipeline wiring | ~15 min |
| `99-teardown.sh [--keep-db] [--snapshot] [--yes]` | Destroys everything | ~25 min |

`env.sh` holds all shared configuration and is sourced by the rest. It generates
`.secrets/platform-secrets.env` once and reuses it forever — Thunder seeds those
values into its database on first boot and never re-seeds, so regenerating them
would silently desynchronise Thunder from every consumer.

## Cluster shape

3 × `c8i-flex.xlarge` (4 vCPU / 8 GiB), 50 GB gp3 each, private subnets behind a
single NAT gateway, AZs pinned to `us-east-1a/b/c` because `c8i-flex` is not
offered in `us-east-1e` and eksctl picks AZs at random.

Cilium replaces both the CNI and kube-proxy (`disableDefaultAddons: true`), in
ENI IPAM mode with native routing, so pods hold real VPC addresses. It must be
installed *between* the control plane and the nodes — with no CNI a node never
reports Ready, so creating the cluster and its nodegroup in one shot would block
until eksctl rolled back. The nodegroup therefore lives in its own
`nodegroup.yaml`: eksctl refuses a `disableDefaultAddons` cluster-create config
that even contains one. `coredns`, `metrics-server`, `aws-ebs-csi-driver` and
`eks-pod-identity-agent` are added back explicitly in `addons.yaml`.

## Deliberate deviations from the guide

**Registry is not ECR.** `publish-image.yaml:31` pushes
`${workflowRunName}-image` — a different repository name on every build run —
and ECR has no push-to-create, so those repositories cannot be pre-created. The
same template mounts a *static* `.dockerconfigjson`, so it would never refresh
ECR's 12-hour token either. `035-registry.sh` runs the CNCF distribution
registry instead, which creates repositories on push. It serves TLS from a
Let's Encrypt certificate behind an **internal** load balancer, with no
authentication: the workflow's push-secret volume is declared `optional`, so it
pushes without an authfile, and containerd pulls agent images without a pull
secret in every `dp-*` namespace. Anything already inside the VPC can push and
pull — put htpasswd in front of it before this carries anything real.

**cert-manager uses pod identity, not an access key.** The guide's DNS-01 example
stores a long-lived IAM secret access key in a cluster Secret. `03` creates an
IRSA service account scoped to the one hosted zone instead.

**OpenBao is initialised non-interactively.** The guide has you record the five
unseal keys by hand. `03` captures them to `.secrets/openbao-init.json` (mode
600) and unseals with three. OpenBao re-seals on every pod restart and those keys
are the only way back in — move them into a real secret manager.

**OpenSearch volume is 50Gi, not 100Gi.** `OPENSEARCH_PV_SIZE` in `env.sh`.

**Let's Encrypt production, not staging.** env-Thunder provisioning runs with
`SKIP_CA_BUNDLE_TRUST=true`, which requires publicly trusted certificates. The
rate limit that bites is 5 *duplicate* certs per week; the four issued here are
distinct names.

## Things that are frozen at install time

Getting these wrong means uninstalling and discarding data, not a `helm upgrade`:

- Thunder's database, its six platform client secrets, `THUNDER_PUBLIC_URL`,
  `CONSOLE_PUBLIC_URL`, and the MCP resource identifiers
- Agent Manager's database
- `gateway.vhost` / `gateway.hostname` on the gateway extension — written at
  first registration only, and later runs log `already exists` and reconcile
  nothing

Discarding Thunder's data also recreates the organization, which orphans every
organization-scoped row Agent Manager holds. Treat it as a platform-data reset.

## Environments are provision-once

`04` creates the `default` environment with a single BOTH-role gateway (the
guide's shape). Further environments come from `07-add-environment.sh`, which
provisions split INGRESS/EGRESS gateways, an env-Thunder, and adds the
environment to the default deployment pipeline as a promotion target of
`default`.

There is no reshape-in-place: gateway role, vhost and hostname freeze at first
registration, and the Agent Manager API refuses to deregister a gateway that
has ever held deployment records — the check counts rows regardless of status,
so even fully UNDEPLOYED/ARCHIVED test deployments block it permanently. Pick
the topology at creation time. Env names cap at **8 characters** for org
`default` in split topology (the generated egress gateway Service name hits
Kubernetes' 63-char limit) — hence `prod`, not `production`.

## Access modes

`./05-access.sh vpn` restricts every internet-facing endpoint to WSO2's VPN
egress CIDRs (read from `vpn.env`, gitignored — values come from WSO2 IT);
`./05-access.sh public` reopens everything. Both are idempotent and safe to
flip repeatedly.

The internet-facing surface is **five** load balancers, not three: the plane
gateways in the control, data and observability namespaces, plus the Thunder
extension gateway (`:8443`, control plane) and the observability Prometheus —
those last two are just as public as the gateways. The registry LB is internal
and untouched. vpn mode also restricts the EKS API endpoint's
`publicAccessCidrs`, always appending this machine's current public IP as a
lockout guard.

The mechanism is `spec.loadBalancerSourceRanges` patched straight onto the
Services. kgateway (v2.2.1) does **not** revert the patch — verified through a
forced Gateway reconcile and a full controller restart; its server-side apply
never claims that field. The patch is only lost if a Service is deleted and
recreated (chart reinstall) — re-run the script afterwards.

**The NAT-EIP hairpin:** in-cluster components call the platform's *public*
hostnames (Thunder token/JWKS, observer, agent trace export), so their traffic
leaves through the VPC's NAT gateway and re-enters via the public LBs. vpn mode
automatically appends the NAT gateway's Elastic IP(s) to the allowlist; without
them the platform silently breaks itself while every pod looks healthy.

## Cost

Roughly **$0.85–1.00/hr** with everything running: 3 nodes, EKS control plane,
single NAT gateway, RDS `db.t4g.small`, and four load balancers (three plane
gateways plus the internal registry). Tear it down between sessions.

## Re-running

Every script is written to be re-runnable. The exceptions are guarded rather than
retried: Thunder and the gateway extension detect an existing release and skip,
because both hold frozen state that an upgrade would not fix.
