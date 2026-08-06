# Installation difficulties log

Everything that went wrong (or would have) while standing up Agent Manager
`0.0.0-dev-20260805` on EKS with these scripts, 2026-08-05. Each entry: the
symptom as it appeared, the root cause, and the fix now baked into the scripts.

Tool versions involved: eksctl on EKS 1.34, Cilium 1.19.6, **Helm v4.2.0**
(the guide targets v3.12+ — see §7), PostgreSQL 17.10 on RDS, OpenBao chart
0.25.6, cert-manager v1.19.2.

---

## 1. eksctl refuses `managedNodeGroups` alongside `disableDefaultAddons`

**Symptom** — `./01-cluster.sh` failed instantly:

```
Error: fields nodeGroups, managedNodeGroups, fargateProfiles, karpenter, gitops,
iam.serviceAccounts, and iam.podIdentityAssociations are not supported during
cluster creation in a cluster without VPC CNI if Auto Mode is disabled
```

**Cause** — eksctl validates the *whole config file*, not just what it is about
to create. With `disableDefaultAddons: true` (no VPC CNI), it rejects any
config that so much as contains a `managedNodeGroups` block — `--without-nodegroup`
does not exempt it.

**Fix** — the nodegroup moved into its own `nodegroup.yaml`. `cluster.yaml`
creates the control plane, Cilium is installed while zero nodes exist, then
`eksctl create nodegroup -f nodegroup.yaml`. Nothing had been created in AWS
(the failure is pure client-side validation), so the re-run was clean.

## 2. `kubectl delete svc lbtest deploy lbtest` deletes the wrong things

**Symptom** — end of `01-cluster.sh`:

```
Error from server (NotFound): services "deploy" not found
```

and the `lbtest` Deployment was left running.

**Cause** — that syntax means "delete the *Services* named lbtest, deploy, and
lbtest". The resource type does not reset mid-argument-list.

**Fix** — `kubectl delete svc/lbtest deploy/lbtest`. Cosmetic: the LoadBalancer
smoke test itself had already passed (address in ~5 s); only the cleanup and
the final "Cluster ready" message were lost.

## 3. RDS PostgreSQL 17: master user cannot `CREATE DATABASE ... OWNER <role>`

**Symptom** — `./02-rds.sh`, right after successfully creating the roles:

```
ERROR:  must be able to SET ROLE "agentmanager"
```

**Cause** — the RDS master user is not a superuser, and since PostgreSQL 16
creating a database *owned by another role* requires the creator to be able to
`SET ROLE` to it — i.e. to hold membership in it. Plain Postgres tutorials
never hit this because they run as a true superuser.

**Fix** — grant membership before creating the databases (idempotent; a
re-grant is a no-op):

```sql
GRANT agentmanager TO CURRENT_USER;
GRANT thunder TO CURRENT_USER;
```

## 4. `03-openchoreo.sh` "won't execute" — a `set -e` footgun in `env.sh`

**Symptom** — the script exited immediately with status 1 and **no output at
all**. Permissions, shebang, and syntax were all fine.

**Cause** — `require_placeholders_filled()` ended with:

```bash
(( ${#missing[@]} )) && die "Fill these in env.sh first: ${missing[*]}"
```

When nothing is missing, `(( 0 ))` is false, so the function's *last statement*
— and therefore the function itself — returns 1. Under `set -euo pipefail` the
calling script dies on that return value, silently. The cruel part: it only
failed once the configuration was **correct**; with placeholders unfilled it
died loudly as designed.

**Fix** — explicit `if` statements plus a trailing `return 0`. Rule extracted:
under `set -e`, never let a function's last statement be a `cond && action`
list where the condition is expected to be false on the happy path. All other
functions in these scripts were audited for the same shape; the one other hit
(`cluster_reachable` in the teardown) is safe because it is only ever called
as an `if` condition.

## 5. OpenBao init raced the container: "container not found"

**Symptom** — first attempt at Step 2:

```
error: Internal error occurred: unable to upgrade connection: container not found ("openbao")
```

**Cause** — a sealed OpenBao never reports `Ready`, so the script waited on
`--for=condition=Ready=false`. That condition is satisfied the moment the pod
*object* exists — before the image is pulled or the container started — so the
`kubectl exec` for `bao operator init` fired into a container that was not
there yet. There is no pod condition that means "sealed but running".

**Fix** — poll `bao status` itself. Its exit code disambiguates: `0` =
unsealed, `2` = sealed but responding (the expected state here), anything else
= not up yet.

## 6. Helm 4 server-side apply conflict on OpenBao's webhook

**Symptom** — re-running the (otherwise idempotent) OpenBao install:

```
Error: UPGRADE FAILED: conflict occurred while applying object
/openbao-agent-injector-cfg ... MutatingWebhookConfiguration: Apply failed with
1 conflict: conflict with "vault-k8s" ... .webhooks[name="vault.hashicorp.com"].clientConfig.caBundle
```

**Cause** — Helm 4 switched to Kubernetes server-side apply, where every field
has an owner. OpenBao's agent injector rewrites `caBundle` on its own webhook
config at runtime under the field manager `vault-k8s`; on re-apply Helm found a
field it no longer owned and refused. Helm 3 — which the product guide targets —
used client-side three-way merge and never tracked ownership. cert-manager's
cainjector patches `caBundle` the same way and would have thrown the identical
conflict on the next re-run.

**Fix** — `--server-side=false` on every `helm install` / `helm upgrade
--install` in `03`/`04`, restoring Helm 3 apply semantics wholesale. The bare
`helm upgrade` reconfigure calls stay on `--server-side=auto`, which inherits
the client-side method from the release they upgrade. This was the flagged
"Helm v4.2.0 vs a guide written for v3.12+" risk actually biting.

## 7. Zero-byte `openbao-init.json` made a later run skip init and unseal with empty keys

**Symptom** — Step 2 on the next run:

```
An error occurred attempting to ask for an unseal key. ...
The raw error was: file descriptor 0 is not a terminal
```

**Cause** — a two-bug chain. The failed exec in §5 had run as
`kubectl exec ... > "${BAO_INIT_FILE}"`, and the shell truncates/creates the
redirect target *before* the command starts — so the failure left a zero-byte
file behind. The next run's `[[ -f "$BAO_INIT_FILE" ]]` guard took the empty
file as proof of a prior init, skipped `bao operator init`, extracted empty
unseal keys from it with `jq`, and passed empty strings to `bao operator
unseal` — which fell back to prompting for a key on a non-tty.

**Fix** — three layers, because with real keys in that file this failure mode
is unrecoverable data loss rather than an annoyance:
- the guard is now `[[ -s ]]` (non-empty), not `[[ -f ]]` (exists);
- init writes to a `.tmp` file, is validated with `jq -e` (root token present,
  exactly five unseal keys), and only then moved into place;
- the root-token read dies loudly if it comes back empty, warning **not** to
  delete the file in that state.

Deleting the stray empty file was verified safe first: OpenBao itself still
reported `Initialized: false`, so no keys had ever existed.

---

# Nightly upgrade, 2026-08-06 (`0.0.0-dev-20260805` → `0.0.0-dev-20260806`)

Context that makes these upgrades non-optional: the nightly workflow **deletes
the previous night's image tags from GHCR and the previous git tag** before
building. The moment a new nightly lands, the running cluster's images exist
only in the node-local containerd caches — any reschedule onto a fresh node is
an ImagePullBackOff. Upgrade the same day the nightly runs.

## 13. Re-running `04` died on the gateway bootstrap Job wait

**Symptom** — the re-run with the new VERSION failed at Step 7:

```
WARN: Gateway extension already installed — its registered vhost is frozen, skipping install.
Error from server (NotFound): jobs.batch "api-platform-default-default-bootstrap" not found
```

**Cause** — the bootstrap Job is a Helm hook that only exists right after a
fresh install and is garbage-collected afterwards. The script correctly
skipped the guarded `helm install`, then unconditionally `kubectl wait`ed on
the Job; under `set -e` that NotFound killed the script. The failure point
matters more than it looks: the steps *after* it re-apply
`agentManagerService.ocIngress.gatewayMgmt.hostnames` and the Environment
gateway host/port values, which Step 2/Step 4 (plain `--set`, no
`--reuse-values`) had just dropped — stopping there leaves the AI-gateway
endpoint and Environment gateway unwired.

**Fix** — the wait now runs only if the Job exists.

## 14. The API's health endpoint moved from `/health` to `/healthz`

**Symptom** — post-upgrade verification printed
`https://api-amp.../health  404` while traces and console were 200.

**Cause** — not a routing failure: the HTTPRoute forwards `/` to `amp-api`,
and the 404 came from the app. The 20260806 build serves liveness on
`/healthz` (200) and no longer answers `/health`. Confirmed in-pod: `/health`
404, `/healthz` 200.

**Fix** — verification URL updated in `04`. Real API routes were unaffected
(`/api/v1/...` returned 401 as expected without a token).

---

# Environments, 2026-08-06 (adding `prod`, split gateways)

## 15. Gateway deregistration is blocked forever by stale deployment records

**Symptom** — converting the default env's BOTH gateway to split
INGRESS/EGRESS requires deregistering it first (role and vhost are frozen),
but `DELETE /orgs/default/gateways/{uuid}` returned:

```
409 CONFLICT: cannot delete gateway: it has active API deployments.
Please undeploy all APIs before deleting the gateway
```

with nothing visibly deployed.

**Cause** — `HasGatewayDeployments` counts deployment *rows* regardless of
status: five LLM-provider deployment records from earlier UI testing, all
`UNDEPLOYED` or `ARCHIVED`, counted as "active". There is no undeploy API
route either — the records themselves must be deleted one by one via
`DELETE .../llm-providers/{id}/deployments/{deploymentId}`.

**Resolution** — the conversion was abandoned rather than worked around:
environments are treated as provision-once (see README), the default env
keeps its BOTH gateway, and new environments get split gateways from day one
via `07-add-environment.sh`. The conversion script was deleted.

## 16. `production` is an invalid environment name in split topology

**Symptom** — the docs' own example env name fails validation.

**Cause** — the APIGateway controller materializes a Service named
`api-platform-<org>-<env>-egress-gw-gateway-gateway-runtime`, which must fit
Kubernetes' 63-character name limit. For org `default` that caps env names at
8 characters.

**Fix** — `07` enforces the limit up front; the environment is `prod`.

## 17. The pipeline's promotion path lives in Helm values and is easy to lose

**Symptom** — after `prod` was fully provisioned, the console showed no
promotion path: the DeploymentPipeline still read `default → []`.

**Cause** — two gaps. The product's `add-environment.sh` (and the first cut
of `07`) never touches the DeploymentPipeline. And the CR is Helm-owned by
`amp-platform-resources`, so a `kubectl patch` would be reverted on the next
chart upgrade — while a plain `--set`-style upgrade of that release (as in
`04` step 4) *drops* any promotion targets previously stored, because helm
`--set` replaces user-supplied values wholesale.

**Fix** — `07` now merges the new env into
`deploymentPipeline.promotionOrder` and upgrades `amp-platform-resources`
with `--reuse-values`; the `amp` and `amp-platform-resources` upgrades in
`04` carry `--reuse-values` too, so re-runs preserve values layered on later.

---

# Caught while writing the scripts (never hit at runtime)

These were found by reading source/docs before execution; they are recorded
because any of them would have cost an hour on a naive run.

## 8. ECR cannot be the build registry

The platform's `publish-image` workflow template pushes
`${workflowRunName}-image` — a **different repository name on every build** —
and ECR has no push-to-create, so the repositories cannot be pre-created. The
same template mounts a *static* `.dockerconfigjson`, which would never refresh
ECR's 12-hour auth token. `035-registry.sh` runs a CNCF distribution registry
(auto-creates repos on push) behind an internal LB instead. Trade-off: TLS but
no auth — anything in the VPC can push/pull.

## 9. The docs' `VERSION="0.0.0-dev"` is not a published tag

The install pulls values files from
`raw.githubusercontent.com/.../amp/v${VERSION}/`, and `0.0.0-dev` exists
neither as a GHCR chart tag nor as a git tag — it is a local-build placeholder.
Pinned the nightly `0.0.0-dev-20260805` and verified all five referenced paths
return HTTP 200 at that tag before running anything.

## 10. Delegation checks that lie, and apex-vs-subdomain instructions

Two defects in early versions of `00-domain.sh`:
- The check queried the zone's **own** Route 53 nameserver, which is
  authoritative the instant the zone exists — it reported "delegated" with
  zero delegation in place. Fixed to query a public resolver (`@1.1.1.1`) and
  intersect with the zone's delegation set.
- For an apex domain (`lyuda.xyz`) it printed *subdomain* instructions ("add
  NS records to the zone for `xyz`") — but that zone is the TLD registry,
  which nobody can edit. Apex delegation happens at the registrar. The script
  now detects apex vs subdomain and prints registrar instructions (with the
  Namecheap-specific warning that "Advanced DNS" NS records do nothing while
  the domain is on BasicDNS).

Also: bare `dig +short NS <domain>` with no resolver returned empty on this
machine; always query through an explicit resolver.

## 11. Cluster-build gotchas absorbed into the design

- **Cilium ordering** — with no CNI, nodes never report Ready, so cluster and
  nodegroup in one shot blocks until eksctl rolls back. Order: control plane →
  Cilium → nodegroup. Cilium also needs `k8sServiceHost` set explicitly
  (there is no kube-proxy to reach the API via ClusterIP) and
  `eni.subnetTagsFilter` pinned to the private-subnet tag (otherwise pod ENIs
  can land in public subnets with no NAT route).
- **AZ pinning** — `c8i-flex` is not offered in `us-east-1e`, and eksctl picks
  AZs at random; AZs pinned to `us-east-1a/b/c`.
- **The `gp2` trap** — EKS ships a default `gp2` StorageClass bound to the
  removed in-tree provisioner: it accepts PVCs and never binds them. `gp3`
  (EBS CSI) is applied as default and `gp2` demoted.
- **k3d-derived values files** — the guide's `values-dp.yaml`/`values-op.yaml`
  pin gateway ports 19080/11080. On EKS that produces a fully healthy-looking
  install with every published URL pointing at a dead port, so `03` overrides
  the ports and asserts 80/443 on the gateway Services after install.
- **Private RDS, no local psql** — schema extracted from the Thunder image via
  `docker create` + `docker cp` (works on shell-less images), and every psql
  command runs from an in-cluster `postgres:17` pod.

## 12. The public surface is five load balancers, not three

Found while writing `05-access.sh`, which was specified against "the three
plane gateways". Enumerating `kubectl get svc -A --field-selector
spec.type=LoadBalancer` turned up two more *internet-facing* LBs beyond the
`gateway-default` trio and the (internal) registry:

- `amp-thunder-extension-https-gateway` in the control-plane namespace — a
  second kgateway Gateway serving `:8443`, created by the `amp-thunder-extension`
  Helm release;
- `openchoreo-observability-prometheus` — kube-prometheus-stack's Prometheus,
  published straight to the internet on `:9091`/`:8081`.

A VPN lockdown covering only the three named gateways would have left Thunder's
extension port and an unauthenticated Prometheus wide open. `05-access.sh`
restricts all five. Related finding from the same script: kgateway v2.2.1 does
**not** revert a direct `spec.loadBalancerSourceRanges` patch on its generated
Services (verified through a forced Gateway reconcile and a controller
restart — its server-side apply never claims the field), so no
GatewayParameters indirection was needed.
