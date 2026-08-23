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

# Fresh install, 2026-08-09 (`0.0.0-dev-20260809`, split default gateway)

## 18. The kernel check warns that 6.12 is older than 6.3

**Symptom** — `./01-cluster.sh` finished successfully but printed, on nodes
running Amazon Linux 2023 with kernel `6.12.94-123.192.amzn2023`:

```
WARN: Kernel 6.12.94-123.192.amzn2023.x86_64 is below 6.3. User-namespaced agent builds will fail.
WARN: Install the Platform Resources chart with buildWorkflows.userNamespaces=false,
```

**Cause** — the check was
`awk "BEGIN{exit !(${kernel_major_minor} < 6.3)}"`, which compares the version
as a **float**. `6.12 < 6.3` is arithmetically true, so every kernel from 6.10
onward reported as being below 6.3 — the warning gets *more* likely as the AMI
gets newer. The nodes exceed the requirement by nine minor versions.

**Why it mattered** — the warning is not cosmetic: acting on its advice means
installing the Platform Resources chart with
`buildWorkflows.userNamespaces=false`, permanently disabling a working security
feature on the basis of an inverted comparison.

**Fix** — compare with `sort -V` via a `kernel_older_than` helper, unit-tested
against 6.12 / 6.3 / 6.2 / 5.15 / 7.0 / 6.10. The helper opens with an explicit
`if [[ "$have" == "$want" ]]; then return 1; fi` rather than chaining both tests
into one `&&` list, per §4 — it is only ever called as an `if` condition today,
but the shape is the one that silently kills a script under `set -e`.
## 19. A keyfile from a destroyed cluster made a fresh OpenBao skip init

**Symptom** — `./03-openchoreo.sh` on a brand-new cluster logged
`OpenBao already initialised — reusing keys from .secrets/openbao-init.json`
against an OpenBao that had never been touched, then died:

```
Error unsealing: Error making API request.
URL: PUT http://127.0.0.1:8200/v1/sys/unseal
Code: 400. Errors:
* Vault is not initialized
```

**Cause** — the reuse guard is `[[ -s "${BAO_INIT_FILE}" ]]`, and
`99-teardown.sh` deliberately preserves `.secrets/` ("Secrets remain in
${SECRETS_DIR} — delete them if you are done"). So the previous cluster's
keyfile outlives the cluster it belongs to, and on the next install it satisfies
a non-empty check perfectly — init is skipped and three keys from a PVC that no
longer exists are fed to a virgin OpenBao.

This is **§7's blind spot, not a recurrence of it**. §7 hardened the guard from
`-f` to `-s` to defeat a *zero-byte* file; a *well-formed file from a different
cluster* clears that bar just as easily. Both bugs share one root: the guard
interrogates the filesystem when the question is about OpenBao.

**Fix** — the branch now keys off `bao status -format=json`'s `initialized`
flag. It is stricter in both directions:
- `initialized=true` but the file is missing or empty → **die loudly**. Previously
  this fell through to the else branch and re-initialised, which strands the
  existing PVC permanently. This is the dangerous direction and it was unguarded.
- `initialized=false` but a file exists → archive it to
  `openbao-init.json.stale-<timestamp>` and initialise fresh. Archived, not
  deleted: still key material, just for a PVC that no longer exists.

**Note for teardown-and-reinstall cycles** — `.secrets/` is intentionally
reused (`platform-secrets.env` *must* survive, per README), but
`openbao-init.json` is per-cluster state living in the same directory. Anything
added there should be classified as one or the other.

## 20. `03`'s DNS check poisoned this machine's resolver and broke `04`

**Symptom** — `03` reported success, but every request from this machine to
`https://thunder.amp.lyuda.xyz` failed with `Could not resolve host`, while the
same name resolved fine from `@1.1.1.1` and from the authoritative Route 53
nameservers, and the Thunder service answered `200` in-cluster. `console`,
`api-amp` and `traces` all resolved locally; only `thunder` did not.

**Cause** — the "Waiting for DNS to resolve" loop used a bare `dig +short`,
which goes to this machine's stub resolver (127.0.0.53). It ran immediately
after `upsert_dns`, so the first query arrived before Route 53 had published
the record, and `systemd-resolved` cached the NXDOMAIN for the zone's negative
TTL — `min(SOA MINIMUM, SOA TTL)` = 900s. §10 already established the rule
("always query through an explicit resolver") for a *correctness* reason; this
is the same mistake causing a *side effect* on the host.

It surfaces one script later: `04` resolves `${THUNDER_PUBLIC_URL}` from this
machine in `am_token()`, so `03` passing was reliably followed by `04` failing
against a host that works everywhere else.

**Second bug in the same loop** — it `break`-ed on success and simply fell
through when the 30 attempts were exhausted, printing nothing and returning 0.
That is why `thunder` was silently missing from the "resolves" list while `03`
still reported Phase 1 complete. The loop verified nothing it did not already
find.

**Fix** — query `@1.1.1.1` explicitly, and `die` when a name never resolves.
A second loop then checks the same names through `getent` and warns (does not
fail) when one resolves publicly but not locally, naming
`resolvectl flush-caches` as the immediate remedy. The cache entry expires on
its own within 900s.

## 21. `apiPlatformGateway.namespace` must stay empty in split topology

**Context** — with the default environment on split gateways, `04` step 4's
`apiPlatformGateway.namespace` was first set to the ingress namespace
(`default-default`), mirroring the old single-gateway value
(`openchoreo-data-plane`).

**Why that is wrong** — the value feeds
`amp.gatewayRuntimeHost`, which builds the OTEL endpoint every deployed agent
exports traces to. Left empty the chart derives
`api-platform-<org>-<env>-gw-gateway-gateway-runtime.<org>-<env>` from
OpenChoreo trait placeholders resolved *per component*, which is exactly where
split topology puts each environment's ingress half. Pinning it to one
namespace is correct for `default` and silently wrong for every environment
added later by `07` — `prod`'s agents would export traces to `default`'s
gateway, with every pod healthy and no error anywhere.

**Fix** — `--set apiPlatformGateway.namespace=""`. Verified in the rendered
manifest: the endpoint is now
`api-platform-${metadata.componentNamespace}-${metadata.environmentName}-gw-gateway-gateway-runtime.${metadata.componentNamespace}-${metadata.environmentName}:22893/otel`.


## 22. Thunder 1.0.0-beta changed its database layout, and the chart said nothing

**Symptom** — on the `0.0.0-dev-20260816` nightly, `03` died in step 4:

```
Error: INSTALLATION FAILED: failed pre-install: resource Job/amp-thunder/amp-thunder-extension-setup
not ready. status: Failed, message: Job Failed. failed: 1/1
```

The job controller deletes the failed pod, so `kubectl logs` returns nothing and
the namespace looks empty. Recreating the pod from the Job's own template with
`restartPolicy: Never` preserves the logs:

```
kubectl get job -n amp-thunder amp-thunder-extension-setup -o json \
| jq '{apiVersion:"v1",kind:"Pod",metadata:{name:"thunder-setup-debug",namespace:"amp-thunder"},
       spec:(.spec.template.spec | .restartPolicy="Never")}' | kubectl apply -f -
```

which gave the real error:

```
pq: relation "SERVER_CONFIG" does not exist
pq: column "signout_flow_id" does not exist
```

**Cause** — two skews at once, and the dangerous one was silent.

*Schema.* `02-rds.sh` pinned `thunderid:0.45.0` to extract `dbscripts/`, while the
chart runs `thunderid:1.0.0-beta`. The schema and the binary that reads it are
versioned together.

*Topology.* 1.0.0-beta replaced `configdb`/`runtimedb`/`userdb` with **four**
datasources: `config`, `entity`, `runtime_persistent`, `runtime_transient`. The
chart does not validate datasource keys — `runtime:` and `user:` matched nothing
and were dropped without a warning, and the three unnamed datasources fell back
to the chart default of **SQLite on a PVC**. Read back from the cluster:

```
kubectl get cm -n amp-thunder amp-thunder-extension-setup-config-map \
  -o jsonpath='{.data.deployment\.yaml}'
```

`config` was postgres; `entity`, `runtime_persistent` and `runtime_transient`
were all `type: "sqlite"`. Had the schema matched, the install would have gone
**green with three quarters of Thunder's state on one pod's local disk** —
surviving no reschedule, and invisible until it was lost.

**Fix** — `THUNDER_DBS` in `env.sh` now names the four databases and doubles as
the datasource-key list; the map in `03` sets all four to postgres explicitly.
`02` pins `1.0.0-beta` and, because nightlies move it, **verifies the pin against
the chart** before provisioning anything:

```
CHART_THUNDER_TAG="$(helm show values oci://.../wso2-amp-thunder-extension \
  --version "${VERSION}" | awk '...')"
[[ "${THUNDER_IMAGE##*:}" == "${CHART_THUNDER_TAG}" ]] || die ...
```

**The general rule** — a Helm value that no template reads is not an error, it is
a default. Every silent fallback here pointed the same way: away from RDS and
onto ephemeral local disk. When a chart's datasource keys change, a stale map
does not fail the install; it relocates the data. Re-read the rendered config
from the cluster after any chart version bump rather than trusting that the
values were applied.

## 23. The nightly moved to OpenChoreo 1.2.0, and Helm will not upgrade `crds/`

**Symptom** — `04` died at step 4 on the `0.0.0-dev-20260816` nightly:

```
Error: unable to build kubernetes objects from release manifest:
[resource mapping not found for name: "default" namespace: "" from "":
no matches for kind "ClusterProjectType" in version "openchoreo.dev/v1alpha1"
ensure CRDs are installed first, resource mapping not found for name:
"default-default" ... no matches for kind "ProjectReleaseBinding" ...]
```

Nothing in the message mentions a version. `03` had reported success and every
pod was Ready.

**Cause** — each nightly is built against one OpenChoreo line, and its extension
charts reference that line's CRDs. This nightly wants **1.2.0**; the scripts
pinned **1.1.1**, which ships neither kind (33 CRDs installed, 36 in the 1.2.0
chart, 4 missing). The authoritative pin list is upstream, not in this repo:

```
curl -s https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}/deployments/setup/env.sh
```

Comparing it against ours showed **four** stale pins, not one — the control/data/
workflow/observability planes (1.1.1 → 1.2.0), the gateway operator (0.10.1 →
0.11.0), logs-opensearch (0.4.1 → 0.5.3) and tracing-opensearch (0.4.1 → 0.6.0).

**The trap** — the OpenChoreo charts keep CRDs in `crds/`, which Helm installs on
**first install only and never on upgrade** (this is Helm behaviour, not a chart
bug: it refuses to touch cluster-scoped resources whose deletion would destroy
data). So bumping `OPENCHOREO_VERSION` on its own reproduces the *identical*
error, which reads as "the bump didn't work" rather than "the CRDs didn't move".
Only the control plane (36) and observability plane (1) ship CRDs; the data and
workflow plane charts ship none.

**Fix** — every upstream version now lives in `env.sh` as one block so they move
together, and `03` applies the control-plane CRDs explicitly before the upgrade:

```
helm pull ...openchoreo-control-plane --version "${OPENCHOREO_VERSION}" --untar ...
kubectl apply --server-side --force-conflicts -f "${CRD_TMP}/openchoreo-control-plane/crds/"
```

Applied, never pruned: deleting a CRD deletes every object of that kind.

**The general rule** — `VERSION` is not one number. Bumping the nightly implies a
whole dependency set, and the failures surface one script later than the wrong
pin, in a message that names a Kubernetes kind rather than a version. Re-read
upstream's `deployments/setup/env.sh` on every nightly bump. Compare it against
`env.sh` in full rather than fixing the single pin the error names.

## 24. The gateway runtime chart version is independent of the operator's

**Symptom** — `04` step 7 installed both gateway halves successfully, both
bootstrap Jobs completed, and then:

```
error: timed out waiting for the condition on apigateways/api-platform-default-default
```

The Helm releases are `deployed` and nothing in their output hints at a problem.
The failure is only visible on the CR:

```
kubectl get apigateway api-platform-default-default -n default-default -o jsonpath='{.status}'
```

```
"reason":"DeploymentFailed", "phase":"Failed",
"message":"Max retries (10) exceeded. Last error: ... Deployment.apps
 \"api-platform-default-default-gw-gateway-gateway-runtime\" is invalid:
 [spec.template.spec.containers[0].livenessProbe.httpGet: Forbidden:
  may not specify more than 1 handler type, ...readinessProbe.httpGet: ...]"
```

**Cause** — the gateway operator does not *contain* the gateway runtime; it
deploys a second Helm chart, and **that chart's version is not implied by the
operator's**. The scripts pinned `gateway.helm.chartVersion=1.2.0-beta` (correct
for an older operator, because the unset default predated the controller reading
its control-plane address from config). Under operator 0.11.0 the beta chart
renders liveness/readiness probes carrying two handler types, and the API server
rejects the Deployment. So the operator is healthy, the CR is `Accepted`, and the
thing that fails is a Deployment the operator writes on your behalf.

**Fix** — mirror upstream's `deployments/setup/ensure-gateway-operator.sh` at the
matching tag, which is the only combination the nightly is tested against. Beyond
the chart version that means the controller and runtime **image** pins and
**explicit probe handlers**, plus a CRD apply for the operator chart (§23's trap
again — upstream does `helm show crds ... | kubectl apply`). `GATEWAY_CHART_VERSION`
and `GATEWAY_IMAGE_VERSION` now live in `env.sh` beside `GATEWAY_OPERATOR_VERSION`.

**Recovering a Failed ApiGateway** — the operator stops after 10 retries and does
not resume on its own, so fixing the chart version is not enough. Do **not**
reinstall the extension to force it: `gateway.vhost`, `gateway.hostname` and
`gateway.type` are written into Agent Manager at first registration only, and the
API refuses to deregister a gateway that has ever held deployment records (§15).
Force a reconcile instead:

```
kubectl annotate apigateway <name> -n <ns> reconcile-trigger="$(date +%s)" --overwrite
```

**The general rule** — when an operator deploys charts for you, its version pins
a *contract*, not the payload. Every version the operator passes through to a
child chart is a separate pin that has to move with it.

---

## 25. `*.localhost` chart defaults broke identity while everything looked healthy

**Symptom.** The console rendered, but any panel needing identity — user profile,
agent-identity roles — returned 500/502. Nothing looked wrong from the outside:
both `amp-api` replicas `1/1 Running`, Thunder `1/1`, its setup job `Completed`,
all three health endpoints 200, `not-ready count: 0`, and my own
`client_credentials` token from outside the cluster succeeded.

The only signal was in Thunder's access log — a steady trickle of
`POST /oauth2/token HTTP/1.1 400` from two pod IPs, which resolved to the two
`amp-api` replicas. `amp-api`'s own log carried the body:

```
thunder token endpoint returned 400: {"error":"invalid_target",
 "error_description":"The resource parameter does not match any registered resource server"}
```

**Cause.** `agentManagerService.config.thunder.baseURL` is not merely an address.
Agent Manager derives the RFC 8707 `resource` parameter from it
(`client.go`'s `SystemResourceIdentifier`) on every Thunder admin-API token
request. Thunder registers its built-in **System** resource server under the
deployment's public URL, so the two must agree exactly. `04` set
`thunder.clientSecret` but never `thunder.baseURL`, leaving the chart default
`http://thunder.amp.localhost:8080` — a k3d hostname. Confirmed by replaying it
against the token endpoint: it reproduces the identical `invalid_target` body,
while `https://thunder.amp.lyuda.xyz/mcp` and the `urn:wso2:amp` default both
return 200.

Upstream's `setup-platform.sh` never overrides these because its entire flow is
local, so there is no production reference to copy — the chart's own `values.yaml`
comments are the specification, and they state this exact failure outright.

Five sibling defaults were wrong for the same reason. A sweep of
`helm get values -a` for `localhost` is what surfaced them:

| Value | Was | Why it matters |
|---|---|---|
| `thunder.baseURL` | `http://thunder.amp.localhost:8080` | the `resource` identifier above |
| `thunder.resolveToHost` | internal svc `:8090` | must be **emptied** — see below |
| `thunderHostBaseDomain` | `amp.localhost` | builds `<org>-<env>.thunder.<domain>` |
| `agentsBaseDomain` | `am-gateway.localhost` | added environments resolve nowhere |
| `gatewayBaseDomain` | `gateway.localhost` | same |
| `agentsHttpPort` | `19080` | k3d port map; must match `environment.gateway.http.port` (80) |

`resolveToHost` deserves care: it exists so a `*.localhost` `baseURL` can still be
dialled in-cluster, but it swaps **only the dial address** — the scheme still
comes from `baseURL`. Port 8090 is plain HTTP (verified: `http` → 200,
`https` → connection failure), so an `https://` baseURL against it cannot connect.
It must be emptied once `baseURL` is public, which is safe here because the public
name resolves from inside the pod via the NAT hairpin the README already documents.

**Fix.** All six set explicitly in `04`, with the reasoning inline. After the
upgrade: `invalid_target` count 0 across both replicas, every token request 200,
agent-identity roles 500 → 200, and user profile 500 → 403
`"You can only view your own profile"` — the correct RBAC answer for a machine
client, i.e. the call now reaches authorization instead of dying at the token
exchange.

**The general rule** — a chart default that is a *hostname* is a deployment
assumption, not a fallback. Grep every rendered release for `localhost` before
declaring an install healthy; these six all failed silently, none of them at
install time, and no probe or health check anywhere in the platform would have
caught them. Worse, one of them was load-bearing for *authorization* rather than
connectivity, so it produced an error that reads like a Thunder fault when the
misconfiguration was entirely on the caller's side.

---

# rc1 upgrade, 2026-08-23 (`0.0.0-dev-20260816` → `1.0.0-rc1`)

Four of rc1's changes cannot be reached by `helm upgrade` at all, which is why
this release arrives on a fresh cluster rather than in place. Each of the
entries below is one of them, written from the failure it produces on a cluster
that was upgraded instead of rebuilt.

## 26. An environment provisioned before rc1 reads as never provisioned

**Symptom** — after upgrading in place, the console shows the `default`
environment with no Thunder, and `add-environment-thunder.sh` re-runs as if it
were a first provision. The env-Thunder pods are Running the whole time.

**Cause** — env-Thunder hostnames became handle-based in rc1: `thunder_host`
went from `<org>-<env>.thunder.<base>` to `<handle>.<base>`, and upstream
explicitly removed the grandfathering that used to infer a host for an
environment with no handle recorded (*"Remove env-Thunder handle grandfathering
so a missing handle always means not-provisioned"*). Every environment created
before rc1 has no handle, so it now reads as not-provisioned no matter what is
running in its namespace. Re-provisioning does not repair it either: Thunder's
issuer is minted from the host and is immutable once written, so the new handle
gives an issuer that nothing already registered will accept.

**Fix** — the handle is generated once per `(org, env)` by `env_thunder_handle`
in `env.sh`, stored in `.secrets/thunder-handles.env`, and passed explicitly as
`THUNDER_HANDLE` by both `04` and `07`. The API's `PUT
/orgs/{org}/environments/{env}/thunder-url` upserts, so passing the same handle
on a re-run resolves to the same host and the same issuer. Omitting it mints a
fresh generated handle whose value is only discoverable by reading back what the
script printed. For an environment that predates rc1 there is no in-place
repair: register a handle before anything depends on the issuer, or rebuild.

The handles carry an `env-` prefix because agent-manager-service rejects a
`reservedThunderHandles` value (`console`, `api`, `thunder`, …) — those would
collide with the platform's own fixed subdomains under the same base domain.

## 27. Console login fails with the documented `admin` / `admin`

**Symptom** — a fresh rc1 install comes up healthy and the console's sign-in
form rejects the credentials the guide gives.

**Cause** — the chart's `defaultUsers` entry no longer carries
`password: "admin"`. A new `admin-credentials.yaml` template resolves the
password from `thunder.setup.admin.password`, else a previously stored value,
else `randAlphaNum 10`, and writes the result to Secret `amp-admin-credentials`
in the Thunder namespace. Leaving the value unset — which is what this install
does, and what upstream documents as the production path — means the password
is generated and never printed anywhere.

**Fix** — `03` reads it straight after the Thunder rollout and files it at
`.secrets/console-admin-password.txt` (mode 600):

```bash
kubectl get secret amp-admin-credentials -n "${THUNDER_NS}" \
  -o jsonpath='{.data.password}' | base64 -d
```

The Secret is created by a `pre-install` hook at weight `-20`, so it is there on
the already-installed path too, not only on a fresh install. Without this step
the install finishes with no way into the console at all.

## 28. Gateways disagree about which policies are active

**Symptom** — a policy change applied through the console takes effect for some
requests and not others, and two gateways report different active policy sets
for the same API. Nothing is unhealthy; retrying the read flips the answer.

**Cause** — rc1 added `gatewayManifestCache` to the amp chart and defaults it to
an in-process `memory` cache. The chart's own values document it as safe only at
one replica: each `amp-api` replica observes only the manifest pushes routed to
it, so with two replicas each holds a partial view and answers from it. `04` ran
two replicas, which is exactly the configuration this breaks.

**Fix** — `04` sets `agentManagerService.replicaCount=1` and
`agentManagerService.autoscaling.minReplicas=1`; both are needed because the HPA
is enabled by default and will otherwise move the Deployment on its own.
`console.replicaCount` and the observer's stay at 2 — neither holds shared
state. Running more than one `amp-api` replica requires switching
`gatewayManifestCache` to a Redis backend first.

## 29. `amp:agent:promote` and `amp:agent:deploy-*` scopes are rejected

**Symptom** — a token request naming those scopes comes back without them, or a
call made with one 403s, on a cluster whose console still lists them in its role
editor.

**Cause** — rc1 renamed three actions in the `amp` permission tree:
`amp:agent:promote`, `amp:agent:deploy-non-production` and
`amp:agent:deploy-production` became `amp:agent:env-non-production` and
`amp:agent:env-production`. The token audience default moved at the same time,
from `amp` to `urn:wso2:amp`, across the API, console and observer. Thunder's
bootstrap is a `pre-install` hook, and `helm upgrade` never re-runs it — so a
database seeded before the rename keeps offering the old scope names from the
console's role editor while nothing downstream accepts them.

**Fix** — use the new names. These scripts never hardcode either the scopes or
the audience, so a fresh install inherits rc1's defaults with no edit; the
rename is one of the reasons a re-used Thunder database would be wrong. The
scopes `07-add-environment.sh` requests (`amp:environment:*`, `amp:gateway:*`)
were not touched by the rename.

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

**Since rc1 it is four, not five.** `03` installs Thunder with
`thunder.ocIngress.https.enabled=false`, which drops
`amp-thunder-extension-https-gateway` along with the self-signed "AMP Local Dev
CA" chain behind it. Both were k3d scaffolding: on k3d `gateway-default` serves
plain `:8080`, so Thunder needs its own TLS terminator on the port k3d maps,
whereas here `gateway-default` already terminates on 443 with the real
Let's Encrypt wildcard — and the Thunder HTTPRoute attaches to it either way, so
nothing is lost but an NLB. `05-access.sh` keeps the target in its list and
skips any Service that is not present, because that list is not
order-independent: dying on a missing target would leave Prometheus, the entry
after it, unpatched on a `vpn` run.
