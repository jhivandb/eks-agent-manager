# Agent Manager 1.0.0-rc1 on EKS — design

Moves this repo's install scripts from the nightly `0.0.0-dev-20260816` to the
released tag `amp/v1.0.0-rc1`, and re-shapes the nodegroup to 8-vCPU nodes.
The target is a **fresh cluster**, built by running `00` through `04` in order.

## Why a fresh cluster

Three of rc1's changes cannot be reached by `helm upgrade`:

- env-Thunder hostnames became handle-based, and upstream explicitly removed
  grandfathering (`Remove env-Thunder handle grandfathering so a missing handle
  always means not-provisioned`). An environment provisioned under the old
  `<org>-<env>.thunder.<base>` scheme reads as unprovisioned, and Thunder's
  issuer is immutable once minted.
- The `amp` permission tree renamed three actions, and Thunder's bootstrap is a
  `pre-install` hook that `helm upgrade` never re-runs.
- EKS managed nodegroups have an immutable `instanceType`, so the node change
  needs a new nodegroup regardless.

## Decisions

| Decision | Choice |
|---|---|
| Cluster | Fresh build, `00`→`04` |
| Nodes | 3 × `c8i-flex.2xlarge` (8 vCPU / 16 GiB) |
| `amp-api` replicas | 1, `gatewayManifestCache` left on `memory` |
| env-Thunder DNS | `*.${BASE_DOMAIN}` wildcard **and** an explicit per-environment handle |
| MCP resource servers | Follow the guide exactly; add nothing |
| Execution | Staged, with a verify gate between scripts |

## Version pins

Verified against `deployments/setup/env.sh` at the rc1 tag and against GHCR:
all six `wso2-*` charts publish a `1.0.0-rc1` tag.

| Variable | From | To |
|---|---|---|
| `VERSION` | `0.0.0-dev-20260816` | `1.0.0-rc1` |
| `GATEWAY_IMAGE_VERSION` | `1.2.0` | `1.2.1` |
| `THUNDER_IMAGE` (`02-rds.sh`) | `thunderid:1.0.0-beta` | `thunderid:1.0.0` |

`GATEWAY_CHART_VERSION` stays `1.2.0`: no 1.2.1 gateway chart was published, and
the image-tag override is what carries the runtime forward. `OPENCHOREO_VERSION`
(1.2.0), `GATEWAY_OPERATOR_VERSION` (0.11.0), the three observability module
versions and `AGENT_SANDBOX_VERSION` are all unchanged.

`THUNDER_DBS` needs no change — `configdb entitydb runtime_persistent
runtime_transient` already matches rc1's datasource keys.

`deployments/single-cluster/values-dp.yaml`, `values-op.yaml` and
`deployments/values/oc-collector-configmap.yaml` are byte-identical between
`1.0.0-beta` and `1.0.0-rc1`; the scripts pull them by tag and need no edit.

## What rc1 changed underneath these scripts

Four changes break the current scripts, and two more are additions the guide now
calls for.

**Handle-based env-Thunder.** `thunder_host` went from
`<org>-<env>.thunder.<base>` to `<handle>.<base>`. The handle is registered with
agent-manager-service (`PUT /orgs/{org}/environments/{env}/thunder-url`) *before*
any cluster mutation, so a collision fails fast instead of orphaning a Helm
release. `add-environment-thunder.sh` takes an optional `THUNDER_HANDLE`
(lowercase alphanumeric with hyphens, no leading/trailing hyphen, 3–63 chars) and
generates a 10-character one when it is omitted.

**Generated console admin password.** The chart's `defaultUsers` entry no longer
carries `password: "admin"`. A new `admin-credentials.yaml` template resolves the
password from `thunder.setup.admin.password`, else a previously stored value,
else `randAlphaNum 10`, and writes it to Secret `amp-admin-credentials` in the
Thunder namespace. Leaving the value unset is the documented production path.

**`gatewayManifestCache`.** New on the amp chart, defaulting to in-process
`memory`, documented as safe only at one replica: each replica only observes the
manifest pushes routed to it, so replicas would disagree about which policies
gateways report. `04` currently runs two replicas.

**Permission scope rename.** `amp:agent:promote`, `amp:agent:deploy-non-production`
and `amp:agent:deploy-production` became `amp:agent:env-non-production` and
`amp:agent:env-production`. The token audience default also moved from `amp` to
`urn:wso2:amp` across the API, console and observer. These scripts never hardcode
either, so they inherit the new defaults — no edit needed, but the rename is why
a re-used Thunder database would be wrong.

**Additions the guide now calls for:** `thunder.ocIngress.https.enabled=false`,
and `console.config.thunderHostBaseDomain` / `console.config.tlsEnabled` /
`agentManagerService.config.agentsHttpsPort` on the amp chart.

### MCP resource servers — deliberately untouched

rc1 rewrote Thunder's bootstrap from a bash-script ConfigMap into declarative
YAML documents, and the `{{- range .Values.thunder.bootstrap.mcpResourceServers }}`
loop was not carried over. The rc1 ConfigMap contains exactly two
`resource_type: resource_server` documents — `60-amp-resource-server.yaml`
(`urn:wso2:amp`) and `70-fix-thunder-system-rs-identifier.yaml` (Thunder's own
System server) — so `thunder.bootstrap.agentManagerMcpBaseUrl` and
`observerMcpBaseUrl` are inert. The chart's own `values.yaml` says so and points
at `deployments/setup/register-amp-resources.sh` as a manual fallback; that
script is itself stale against rc1 (it registers identifier `amp`, not
`urn:wso2:amp`).

The canonical guide says none of this — at both the rc1 tag and the published
page it still instructs setting the two values and states that they become the
registered identifiers. **This design follows the guide.** The two `--set` flags
stay exactly as written, and no registration step, verification check or
troubleshooting entry is added for MCP.

---

## Changes by file

### `env.sh`

1. `VERSION="1.0.0-rc1"`, `GATEWAY_IMAGE_VERSION="1.2.1"`.
2. Rewrite the header comments that describe `VERSION` as a nightly that moves
   daily and deletes the previous day's images. It is a stable tag now, and the
   `0.0.0-dev` placeholder caveat no longer applies.
3. New helper `env_thunder_handle <org> <env>`, backed by
   `.secrets/thunder-handles.env`. It generates one unguessable handle per
   environment on first call and reuses it forever, following the same
   generate-once-and-guard pattern as `generate_platform_secrets`:

   ```bash
   env_thunder_handle() {
     local org="$1" env_name="$2"
     local f="${SECRETS_DIR}/thunder-handles.env"
     local key="THUNDER_HANDLE_${org//-/_}_${env_name//-/_}"

     [[ -f "$f" ]] && source "$f"
     if [[ -z "${!key:-}" ]]; then
       mkdir -p "${SECRETS_DIR}"; chmod 700 "${SECRETS_DIR}"
       local handle="env-$(openssl rand -hex 5)"
       umask 077
       echo "export ${key}=\"${handle}\"" >> "$f"
       chmod 600 "$f"
       export "${key}=${handle}"
     fi
     printf '%s' "${!key}"
   }
   ```

   The `env-` prefix keeps the handle clear of `reservedThunderHandles`
   (`console`, `api`, `thunder`, …), which agent-manager-service rejects because
   they would collide with the platform's own fixed subdomains under the same
   base domain. Ten hex characters give the label its unguessability.

The file is sourced by every script, so the helper is available everywhere
without a second include.

### `nodegroup.yaml`

`instanceType: m8i-flex.xlarge` → `c8i-flex.2xlarge`. Capacity (3/3/5), volume
(50 GB gp3, encrypted), `privateNetworking`, the `node.cilium.io/agent-not-ready`
taint and the IAM block are all held as-is.

Two values must be re-derived for the new instance type before this runs — both
fail quietly if wrong, and both need AWS credentials to check:

- **`maxPodsPerNode: 110`** was derived for the xlarge ("4 ENIs × 30 IPs can
  hold ~117"). Cilium runs ENI IPAM with native routing, so pods hold real VPC
  addresses and this ceiling is real, not advisory. Confirm against
  `aws ec2 describe-instance-types --instance-types c8i-flex.2xlarge
  --query 'InstanceTypes[].NetworkInfo'` and lower it if the 2xlarge's ENI/IP
  budget is smaller. Overcommitting strands pods as unschedulable with no
  message that names the cause.
- **AZ availability.** `cluster.yaml` pins `us-east-1a/b/c` because `m8i-flex` is
  not offered in `1e` and eksctl picks AZs at random. Confirm `c8i-flex.2xlarge`
  is offered in all three with `aws ec2 describe-instance-type-offerings
  --location-type availability-zone --filters
  Name=instance-type,Values=c8i-flex.2xlarge`. If it is not, adjust
  `availabilityZones` in `cluster.yaml` to match — and note that
  `cluster.yaml`'s comment naming `m8i-flex` becomes wrong either way.

### `cluster.yaml`

Comment-only in the expected case: the `availabilityZones` block is pinned with
a comment naming `m8i-flex.xlarge` as the reason, which becomes wrong. If the AZ
check above shows `c8i-flex.2xlarge` is not offered in all three of
`us-east-1a/b/c`, the pinned list changes too.

### `02-rds.sh`

1. `THUNDER_IMAGE="ghcr.io/thunder-id/thunderid:1.0.0"`. The existing guard reads
   the tag out of the chart with `helm show values` and dies on mismatch, so this
   edit verifies itself on the next run.
2. Assert the loaded table counts rather than only printing them. rc1's guide
   states the expected numbers, and an empty or partly-loaded database does not
   fail the install — it fails Thunder's `pre-install` hook minutes later with
   `Server failed to start within 60 seconds`, on a pod that has already been
   deleted:

   | Database | Expected tables |
   |---|---|
   | `configdb` | 20 |
   | `entitydb` | 5 |
   | `runtime_transient` | 13 |
   | `runtime_persistent` | 7 |

   Keyed by database name, not by position in `THUNDER_DBS`.

### `03-openchoreo.sh`

1. Add `--set thunder.ocIngress.https.enabled=false` to the Thunder install.
   The default `true` stands up a second, dedicated Gateway plus a self-signed
   "AMP Local Dev CA" certificate so a k3d install can reach Thunder over HTTPS
   without the control plane's gateway TLS. Here every plane already has its own
   LoadBalancer and a real wildcard certificate, so it is an unused Gateway and
   certificate.
2. Drop `- "*.thunder.${BASE_DOMAIN}"` from the `cp-gateway-tls` Certificate.
   Handles sit directly under the base domain now, so the existing
   `*.${BASE_DOMAIN}` SAN already covers every env-Thunder host. Replace the
   "why the third name" comment.
3. In Step 10, replace `upsert_dns "*.thunder.${BASE_DOMAIN}" "${CP_LB}" CNAME`
   with `upsert_dns "*.${BASE_DOMAIN}" "${CP_LB}" CNAME`. rc1 makes this wildcard
   **required**, not one of two layouts: per-environment Thunder hostnames are
   created after install and are not known up front. The four explicit records
   (`console`, `api-amp`, `thunder`, `cp`) stay — they document intent, and the
   RFC 4592 empty-non-terminal hazard that made them load-bearing disappears
   along with the nested wildcard. `traces` and `agents` keep their explicit
   records and still win over the wildcard.
4. After the Thunder rollout completes, capture the generated console admin
   password, mirroring what `04` already does for the env-Thunder one:

   ```bash
   kubectl get secret amp-admin-credentials -n "${THUNDER_NS}" \
     -o jsonpath='{.data.password}' | base64 -d \
     | tee "${SECRETS_DIR}/console-admin-password.txt"
   chmod 600 "${SECRETS_DIR}/console-admin-password.txt"
   ```

   The Secret is created by a `pre-install` hook at weight `-20`, so it exists on
   both the fresh-install and the already-installed-skip paths. Without this step
   the install finishes with no way to log into the console.
5. `--set thunder.bootstrap.agentManagerMcpBaseUrl` and `observerMcpBaseUrl` are
   left exactly as they are.

### `04-agent-manager.sh`

1. `agentManagerService.replicaCount=1` and `autoscaling.minReplicas=1`.
   `gatewayManifestCache` stays on its `memory` default. `console.replicaCount`
   stays 2 and the observer's stays 2 — neither holds shared state. Rewrite the
   comment that currently explains why both replica values are set to 2.
2. Add to the amp install:
   - `--set agentManagerService.config.agentsHttpsPort=443`
   - `--set console.config.thunderHostBaseDomain="${BASE_DOMAIN}"`
   - `--set-string console.config.tlsEnabled=true`

   `--set-string` on the console value specifically: the chart declares
   `console.config.tlsEnabled` as a quoted string (`"false"`) while
   `agentManagerService.config.tlsEnabled` is a real bool. Plain `--set` would
   write a bool into the string field. The guide's own command uses plain `--set`
   for both.
3. Rewrite the `thunderHostBaseDomain` comment, which documents the retired
   `<org>-<env>.thunder.<domain>` shape.
4. Resolve the handle before provisioning env-Thunder and pass it through:

   ```bash
   ENV_HANDLE="$(env_thunder_handle "${GW_ORG}" "${GW_ENV}")"
   # ... THUNDER_HANDLE="${ENV_HANDLE}" \  alongside the existing env vars
   ```

   Passing an explicit handle is what makes this step re-runnable: the API's PUT
   upserts for the same `(org, env)`, so a re-run resolves to the same host and
   the same issuer. Omitting it would mint a fresh generated handle whose value
   is only discoverable by reading back what the script printed.
5. `ENV_THUNDER_ISSUER="https://${ENV_HANDLE}.${BASE_DOMAIN}"`, replacing the
   hardcoded `https://default-default.thunder.${BASE_DOMAIN}`. Both gateway
   halves consume it in the key-manager step, so it must be right before that
   loop runs.
6. `agentManagerService.config.thunder.resolveToHost` stays empty. rc1's own
   comment confirms `baseURL` still supplies the scheme, so pointing
   `resolveToHost` at the plain-HTTP `:8090` service would fail the `https://`
   connection outright.

No change is needed to the env-Thunder credentials: `add-environment-thunder.sh`
mints its AMS token via `get_ams_token`, which requests
`scope=amp:org:manage-service-account` from `IDP_CLIENT_ID` — and rc1's
`50-amp-api-client.yaml` grants `amp-api-client` the full `ampScopes` catalog,
which includes that scope.

### `07-add-environment.sh`

1. `ENV_THUNDER_ISSUER` (line 53) built from `env_thunder_handle "${ORG}"
   "${ENV_NAME}"` rather than `${ORG}-${ENV_NAME}.thunder.${BASE_DOMAIN}`.
2. Pass `THUNDER_HANDLE` through to `add-environment-thunder.sh`, same as `04`.
3. The certificate/DNS note at line 245 describes the retired nested-wildcard
   layout and is rewritten.

The 8-character environment-name cap is unaffected — it comes from the generated
egress gateway Service name hitting Kubernetes' 63-character limit, not from any
Thunder hostname.

### `README.md`

- Cluster shape: 3 × `c8i-flex.2xlarge` (8 vCPU / 16 GiB), and the AZ-pinning
  rationale re-worded for the new type.
- Cost: re-estimate the hourly figure for the new instance type.
- Framing: a pinned release, not a nightly that moves daily.
- DNS: the `*.${BASE_DOMAIN}` wildcard is required, and env-Thunder hosts are
  `<handle>.<base>`.
- "Things that are frozen at install time": add the generated console admin
  password and the per-environment Thunder handles.
- Note that `amp-api` runs a single replica, and why.

### `TROUBLESHOOTING.md`

Four new entries, in the existing symptom → root cause → fix shape:

1. **env-Thunder reads as not provisioned after an upgrade.** Handle-based
   naming with grandfathering removed; a missing handle always means
   not-provisioned. Fix: register a handle, or rebuild.
2. **Console login fails with the documented `admin`/`admin`.** rc1 generates
   the password into `amp-admin-credentials`. Fix: the `kubectl get secret`
   read, and where `03` files it.
3. **Gateways disagree about which policies are active.** `gatewayManifestCache`
   defaults to in-process `memory`, safe only at one replica. Fix: one replica,
   or a Redis backend.
4. **`amp:agent:promote` / `deploy-*` scopes rejected.** Renamed to
   `env-non-production` / `env-production`; the audience default also moved to
   `urn:wso2:amp`. Fix: use the new names; a Thunder database seeded before the
   rename keeps offering the old ones from the console's role editor.

Nothing about MCP.

## Unchanged

`00-domain.sh`, `01-cluster.sh`, `035-registry.sh`, `05-access.sh`,
`99-teardown.sh`. Teardown deletes every CNAME and A record under the base
domain by listing the zone, so it collects the new wildcard with no edit.
`01-cluster.sh` reads the nodegroup from `nodegroup.yaml` and already prints and
checks the node facts that matter (kernel, runtime, kubelet), so the instance
type change reaches it without an edit.

## Execution — staged, with gates

Each gate is cheap and mostly already implemented; the point is to fail before
paying for the next stage rather than in the middle of one.

| Stage | Gate before continuing |
|---|---|
| re-auth AWS | `aws eks list-clusters` succeeds |
| pre-flight | `c8i-flex.2xlarge` offered in all three AZs; ENI/IP budget confirms `maxPodsPerNode` |
| `01-cluster.sh` | 3 nodes Ready; kernel ≥ 6.3; LoadBalancer smoke test passes (all already in the script) |
| `02-rds.sh` | Four databases exist with the expected table counts |
| `03-openchoreo.sh` | Thunder's issuer equals `THUNDER_PUBLIC_URL`; `*.${BASE_DOMAIN}` resolves; `console-admin-password.txt` is non-empty |
| `035-registry.sh` | Registry reachable in-VPC |
| `04-agent-manager.sh` | Both `apigateway` objects `Programmed`; `/healthz`, `/health` and the console return 200; env-Thunder pods Running under the resolved handle |

A failure at `03` or `04` costs a partial teardown, because Thunder's database
and the gateway registrations both freeze at first install.

## Open items

These need AWS credentials and are resolved during the pre-flight gate:

1. `c8i-flex.2xlarge` availability in `us-east-1a/b/c`.
2. The instance type's ENI/IP budget, which sets `maxPodsPerNode`.
3. Whether the existing `amp-test` cluster still exists and must be torn down
   first, and whether its RDS instance and Route 53 zone are being reused.

## Out of scope

- gVisor and Kata isolation tiers. rc1 ships setup scripts for both, but they
  need dedicated nodes with their own hardware requirements.
- Redis for `gatewayManifestCache`, rate limiting, or Thunder's cache — all only
  needed above one replica.
- MCP resource-server registration, per the decision above.
- Any change to the split INGRESS/EGRESS gateway topology, which is frozen at
  first registration and is not affected by rc1.
