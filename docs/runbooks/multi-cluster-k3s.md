# Multi-cluster K3s Runbook

> Status: active

Operator guide for running multiple K3s clusters in one account: bootstrap, HA control plane via slice 3 VIP failover, kubeconfig retrieval, and cross-cluster operator workflows.

**Audience:** operators running multi-environment fleets (prod + staging, multi-region, multi-tenant); SREs managing K3s upgrades.

> ## ⚠️ Phase 3 (adding workers to a chosen cluster) is NOT IMPLEMENTED
>
> **Bootstrapping a second cluster works. Putting a worker in a specific one
> does not.** `target_cluster_id` is wired on the platform side and unreachable
> from the agent, so once a second cluster exists in the account, k3s-agent
> joins are **refused** — `AmbiguousClusterError`, with
> `system.k3s_ambiguous_cluster_join_refused` emitted at severity `high`. The
> worker does not join the wrong cluster; **no node is produced at all**.
>
> Earlier revisions of this page said the opposite — that omitting
> `target_cluster_id` makes the agent "auto-select the most recent active
> cluster" and join the wrong one. That fallback does not exist for a
> multi-cluster account. If you followed this guide, set the field, saw the
> assignment call succeed, and went looking for a misplaced node: there is no
> misplaced node, and nothing you can set on the assignment will change the
> outcome today.
>
> The withdrawn instructions are kept visible in [Phase 3](#phase-3--add-workers-to-a-specific-cluster--not-implemented),
> alongside what is actually true. Phases 1 and 2 (bootstrapping each cluster)
> are unaffected. The producer is tracked separately (IMP-a5f236e8cc56 gap 3);
> this page will be restored when it lands.
>
> **Phase 4 (HA control plane) is NOT covered by this correction and should not
> be read as verified.** A review of this page found evidence that a second
> `k3s-server` does not join the existing cluster's etcd at all — the k3s-server
> installer writes no join material (`WriteJoinConfig` exists only on
> `ShellAgentApplier`) — which would mean Phase 4 *creates a second cluster*
> rather than extending the first, and is therefore the very thing that trips
> the Phase 3 refusal for every later worker. That is a separate finding, filed
> and not yet remediated; the Phase 4 text below is unchanged and unconfirmed.

## When to use multi-cluster

Multi-cluster is the right architecture when:

- You need **environment isolation** (prod vs staging) — separate clusters means independent upgrade cadences and failure domains
- You're running **multi-region** workloads — a cluster per region keeps API latency low
- You're providing **multi-tenant** Kubernetes-as-a-service — one cluster per tenant means clean trust boundaries (and a separate `Sdwan::Network` per tenant lets you use per-tenant `pod_subnet_prefix` for encrypted-pod-plane isolation — see "Per-tenant pod plane" below)
- You need **independent K3s versions** across workloads

### Per-tenant pod plane (encrypted pod-to-pod between tenants)

For multi-tenant K8s-as-a-service, the cleanest isolation pattern is:

1. **One `Sdwan::Network` per tenant** — each tenant's k3s nodes peer on their own /64 overlay
2. **A distinct `pod_subnet_prefix` per network** — e.g., tenant A gets `10.42.0.0/16`, tenant B gets `10.43.0.0/16`
3. **k3s clusters bootstrap with `cni_plugin: "flannel"`** — the platform stamps each cluster's `flannel_iface` / `flannel_backend=host-gw` / `cluster_cidr` from its network's `pod_subnet_prefix`

Result: tenant A's pod traffic flows over `wg-sdwan-<tenant-a-handle>` (encrypted by A's WG tunnels), tenant B's over `wg-sdwan-<tenant-b-handle>` (encrypted by B's WG tunnels). No shared transport for pod traffic. The platform's overlap validation refuses any operator attempt to assign the same `pod_subnet_prefix` to two networks in the same account.

For ovn-Kubernetes clusters (heavyweight tenants), the per-tenant `pod_subnet_prefix` is ignored — OVN owns its own pod-network layer. ovn-K8s tenants get OVN-tunnel-level encryption automatically.

Stick to single-cluster when:

- Workloads are homogeneous and small (<50 pods total)
- You need cross-workload service discovery (a single cluster's service mesh is simpler than cross-cluster federation)
- Cost is paramount — N control planes cost N× more than 1

## Phase 1 — Bootstrap cluster A ✅

```javascript
// Step 1: provision a NodeInstance for the control plane
platform.system_create_node({ hostname: "k3s-prod-server-1", node_template_id: "<k3s-server-template>", ... })
platform.system_provision_instance({ node_id: "<node-id>", ... })

// Step 2: ensure SDWAN peer is attached (REQUIRED for slice 3 VIP failover)
platform.system_sdwan_attach_peer({ network_id: "<sdwan-net>", node_instance_id: "<instance-id>" })

// Step 3: assign the k3s-server module
platform.system_assign_module_to_template({
  template_id: "<k3s-server-template>",
  // The template-assignment verbs take the NodeModule UUID, not its name — system_list_modules returns { id, name }.
  module_id: "<k3s-server-module-id>"
  // No target_cluster_id needed for the bootstrap node — it CREATES the cluster
})
// → wait ~90s for cluster bootstrap

// Step 4: verify cluster appears
platform.kubernetes_list_clusters()
// → { clusters: [{ id, name, flavor: "k3s", status: "active", api_endpoint, ... }] }
```

The cluster's `api_endpoint` is an `Sdwan::VirtualIp` (slice 3) — `https://[fd00:abcd:1::100]:6443`. The bootstrap server is the VIP's primary holder.

## Phase 2 — Bootstrap cluster B (separate cluster, same account) ✅

Same steps as Phase 1, but with a different `Template`:

```javascript
platform.system_create_node({ hostname: "k3s-staging-server-1", node_template_id: "<k3s-staging-template>", ... })
platform.system_provision_instance({ node_id: "<node-id>", ... })
platform.system_sdwan_attach_peer({ network_id: "<sdwan-net>", node_instance_id: "<instance-id>" })
platform.system_assign_module_to_template({
  template_id: "<k3s-staging-template>",
  module_id: "<k3s-server-module-id>"
})

// Wait ~90s, then:
platform.kubernetes_list_clusters()
// → { clusters: [
//      { id: "cluster-prod-id",    name: "k3s-prod-server-1",    status: "active" },
//      { id: "cluster-staging-id", name: "k3s-staging-server-1", status: "active" }
//    ] }
```

Two clusters now exist; their `api_endpoint` VIPs are different `/128` addresses.

## Phase 3 — Add workers to a specific cluster ❌ NOT IMPLEMENTED

**There is no supported way to place a worker in a chosen cluster today.** Once
a second non-error cluster exists in the account, every k3s-agent join is
refused. Read this section before you provision workers into a multi-cluster
account — the failure is at join time, not at assignment time, so the calls all
appear to succeed.

The steps below are **withdrawn**, kept visible so you can recognise them if you
have already run them:

```javascript
// WITHDRAWN — the assignment succeeds and the config is stored, but the
// value never reaches the node. See the table below.
platform.system_provision_instance({ node_id: "<worker-node-id>", ... })

platform.system_assign_module_to_template({
  template_id: "<worker-template>",
  module_id: "<k3s-agent-module-id>",
  config: {
    target_cluster_id: "cluster-prod-id"          // stored; not delivered
  }
})
```

| Withdrawn claim | What is actually true |
|---|---|
| "Without `metadata.target_cluster_id`, agents auto-select the **most recent active cluster**" | There is no most-recent-active fallback for a multi-cluster account. `resolve_membership_cluster!` (`kubernetes_cluster_provisioner_service.rb:351`) auto-selects **only when there is exactly one candidate**; with more than one it raises `AmbiguousClusterError` and the join fails. "Candidate" is `where.not(status: "error")` — so a cluster in `pending`, `bootstrapping`, `degraded` or `disconnected` counts toward the ambiguity, not just an `active` one. Only `error` is excluded. |
| "new workers will join the wrong cluster if you have multiples" | No node is produced at all. The platform emits `system.k3s_ambiguous_cluster_join_refused` at severity `high` (`kubernetes_cluster_provisioner_service.rb:329`) and returns 409. Looking for a misplaced node will not find one. |
| `target_cluster_id: "cluster-prod-id"  // ← REQUIRED for multi-cluster` | Required by the platform, and impossible to supply from the agent. Setting it on the assignment changes nothing about the join. |
| "The agent reads `target_cluster_id` from its module assignment metadata at boot, passes it through to the platform's `runtime/handshake` POST" | The **server** half is real: `handle_join_request` forwards `params[:target_cluster_id].presence` into `join_request!` (`runtime_handshake_handlers.rb:164`), so a value that arrived would be honoured. The **agent** half does not exist. `k3sd.AgentManager.TargetClusterID` is declared (`agent_manager.go:46`) and consumed (`agent_manager.go:151`, passed to `JoinRequest`) but never written: `NewAgentManager` takes five arguments — client, modules, applier, nodeID, onError — none of them a cluster, and its struct literal sets six fields, not including this one. Nor is there a channel that could carry it: `k3sd.ModulesAPI` is `AssignedModules(ctx) ([]string, error)`, module **names** only, so assignment config never reaches the K3s reconcilers. Every worker's `JoinRequest` therefore sends an empty target. |
| "Agent must restart to pick up changes to `target_cluster_id` in module metadata" | Nothing to pick up. A restart, terminate + reprovision, or `system_refresh_instance_modules` all leave the join target empty. |

**What this is wired on one side only means in practice:** the gap is a missing
write on the agent, not a missing feature on the platform. When a producer
lands (IMP-a5f236e8cc56 gap 3), the validation described above — cluster
exists, same account, not in `error` state — is already in place and this
section can be restored roughly as written.

**Single-cluster accounts are unaffected.** With exactly one non-error cluster,
the worker joins it without a target. Assign `k3s-agent` and provision as
normal:

```javascript
platform.system_provision_instance({ node_id: "<worker-node-id>", ... })
platform.system_assign_module_to_template({
  template_id: "<worker-template>",
  module_id: "<k3s-agent-module-id>"
})
```

There is no operator-side workaround for the multi-cluster case. Bootstrapping
the second cluster is what closes the single-cluster window, so if you need
workers on cluster A, add them **before** cluster B exists.

## Phase 4 — HA control plane (≥2 servers) ✅

Slice 3 enables VIP-backed HA: when the primary `k3s-server` goes silent, the VIP fails over to the next `k3s-server` holder. **Requires ≥2 server NodeInstances**.

```javascript
// Provision a second k3s-server bound to the same cluster
platform.system_create_node({ hostname: "k3s-prod-server-2", ... })
platform.system_provision_instance({ node_id: "<node-2-id>", ... })
platform.system_sdwan_attach_peer({ network_id: "<sdwan-net>", node_instance_id: "<instance-id>" })

// Assign k3s-server. NOTE: target_cluster_id is NOT delivered here either —
// see the note below this block.
platform.system_assign_module_to_template({
  template_id: "<k3s-server-template>",
  module_id: "<k3s-server-module-id>"
})

// Wait ~120s for the second server to join etcd. Verify:
platform.kubernetes_list_nodes({ cluster_id: "cluster-prod-id" })
// → { nodes: [
//      { instance_id: "...", role: "control-plane", status: "ready" },
//      { instance_id: "...", role: "control-plane", status: "ready" }
//    ] }
```

> **`target_cluster_id` on a k3s-server assignment is withdrawn for the same
> reason as Phase 3, and one more.** The delivery channel is the same missing
> one (`ModulesAPI` hands over module names only), *and* the k3s-server
> reconciler has no join path to use it: `k3sd.ServerManager` never calls
> `JoinRequest` and never references `TargetClusterID` — it calls `Bootstrap`
> and then reports ready against its own `bootstrappedFor` cluster
> (`server_manager.go:193, 215`). What a second k3s-server's `Bootstrap` does
> to an existing cluster was **not** verified by this correction; treat the HA
> flow below as unchanged from what you have observed, and do not read the
> removal of this field as a statement about it.

The second server is now a VIP failover candidate. `Sdwan::VirtualIp.failover_holder_peer_ids` includes its peer ID.

**Inspect failover candidates, then fail over:**

```javascript
// Who currently holds the VIP and who's queued to take over
platform.system_sdwan_get_virtual_ip({ virtual_ip_id: "<cluster-vip-id>" })
// → { virtual_ip: { id, current_holder_peer_id, failover_holder_peer_ids: [<peer-2>, ...], ... } }

// Manual failover promotes the head of failover_holder_peer_ids to holder.
// Single required param: virtual_ip_id (no dry-run / scoring mode).
platform.system_sdwan_failover_virtual_ip({ virtual_ip_id: "<cluster-vip-id>" })
// → { virtual_ip: { ...new holder... }, failed_over: true }
```

`sdwan_vip_reachability_sensor` automatically fires `system.sdwan_vip_unreachable` when the primary is silent, and the `sdwan_vip_failover` skill (require_approval policy) handles promotion without operator intervention.

## Phase 5 — Get kubeconfig per cluster ✅

```javascript
platform.kubernetes_get_kubeconfig({ cluster_id: "cluster-prod-id" })
// → {
//      kubeconfig: "apiVersion: v1\nclusters:\n  - cluster:\n      server: https://[fd00:abcd:1::100]:6443\n      certificate-authority-data: ...\n  ...",
//      api_endpoint: "https://[fd00:abcd:1::100]:6443"
//    }
```

The `api_endpoint` is the slice 3 VIP — kubectl traffic goes to this address regardless of which server is currently the holder.

**Save and use:**

```bash
# Set up multiple kubectl contexts
echo "$KUBECONFIG_PROD"    > ~/.kube/k3s-prod.yaml
echo "$KUBECONFIG_STAGING" > ~/.kube/k3s-staging.yaml

# Use one
kubectl --kubeconfig ~/.kube/k3s-prod.yaml get nodes
kubectl --kubeconfig ~/.kube/k3s-staging.yaml get nodes

# Or merge into one file with switchable contexts
KUBECONFIG=~/.kube/k3s-prod.yaml:~/.kube/k3s-staging.yaml kubectl config view --merge --flatten > ~/.kube/config
kubectl config use-context k3s-prod
```

Operators must be on the same SDWAN network or have a federation route to reach the api_endpoint VIP.

## Phase 6 — Cross-cluster operator workflows ✅

```javascript
// List all clusters across the account
platform.kubernetes_list_clusters()

// Get specific cluster details (status, version, node count)
platform.kubernetes_get_cluster({ cluster_id: "cluster-prod-id" })

// List nodes in a cluster (control-plane + workers)
platform.kubernetes_list_nodes({ cluster_id: "cluster-prod-id" })

// Decommission an entire cluster (cascades to all member nodes)
platform.kubernetes_decommission_cluster({ cluster_id: "cluster-staging-id" })
// → cascade-deletes all member KubernetesNode rows; underlying NodeInstances are NOT terminated
```

For per-cluster module rolling upgrades, scope by template. **The
`system-rolling-module-upgrade` skill PLANS ONLY — no autonomy reconciler
drives it, and it returns no batches to walk: the upgrade is FLEET-ATOMIC**
(see
[`../tutorials/06-rolling-upgrade.md`](../tutorials/06-rolling-upgrade.md) for
the manual procedure that works). Fleet Autonomy / CVE Responder bind the
skill, so an approved action produces the plan below and stops there. Its
input contract, scoped to one cluster's server template:

```jsonc
// system-rolling-module-upgrade skill inputs — upgrade k3s-server on cluster-prod only
{
  "template_id": "<k3s-prod-server-template>",     // scopes to cluster-prod's servers
  "module_id": "mod-k3s-server",
  "target_version_id": "v-k3s-1.31.0",
  // No batch_pct: the upgrade is FLEET-ATOMIC. current_version_id is a
  // per-MODULE pointer, so every instance carrying mod-k3s-server converges
  // together — including servers in OTHER clusters that share the module row.
  // template_id scopes the PLAN's instance listing, not the pointer.
  "max_consecutive_failures": 1
}
```

> **Per-cluster staging needs a per-cluster module row.** Because the pointer
> is per-module, giving `cluster-prod` a different k3s version from
> `cluster-staging` requires two `NodeModule` rows (each with its own
> `current_version_id`), or replacing instances out of an
> [instance pool](../tutorials/08-instance-pool.md). A percentage never
> delivered this and no longer pretends to.

## Anti-pattern: single-server cluster

`k3s-server` HA requires **≥2 servers** before VIP failover is meaningful. A single-server cluster:

- ✅ Works for development / staging / small workloads
- ❌ Cannot survive bootstrap-node loss — `kubectl` and worker `K3S_URL` connectivity break the moment the only server dies
- ❌ Has the VIP allocated, but failover is no-op when only one candidate remains

**If you start with single-server,** plan to add a second `k3s-server` before going to production. Adding HA later is an online operation (the second server joins etcd; the existing cluster keeps running).

```javascript
// Adding HA mid-life:
platform.system_provision_instance({ node_id: "<new-server-node>", ... })
platform.system_sdwan_attach_peer({ ... })
platform.system_assign_module_to_template({
  template_id: "<existing-server-template>",
  module_id: "<k3s-server-module-id>"
  // config: { target_cluster_id } withdrawn — not delivered; see Phase 4 note
})
// → second server joins etcd; cluster goes from 1-replica to 3-replica (etcd default)
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Worker does not join at all, `system.k3s_ambiguous_cluster_join_refused` (severity `high`) in the event stream | Two or more non-error clusters in the account. The join carries no `target_cluster_id` because nothing on the agent supplies one, and the platform refuses rather than guessing | Expected outcome, not a misconfiguration. There is no fix today — see [Phase 3](#phase-3--add-workers-to-a-specific-cluster--not-implemented). Do not go looking for a misplaced node; none was created |
| Worker stuck in `join_request` phase | API endpoint VIP unreachable | Verify worker is on the same SDWAN network as the cluster's bootstrap server |
| Worker stuck in `join_request`, "bad token" | Token rotated since last cache | Restart `powernode-agent` on the worker; or re-fetch via terminate + reprovision. **⚠️ In a multi-cluster account, do not terminate + reprovision.** Once joined, the worker keeps working because it re-reports readiness against its own cached `joinedClusterID` (`agent_manager.go:170, 191`), which the platform accepts as the target. Anything that clears that cache — cleanup, a stop, or a k3s reinstall (`agent_manager.go:146, 212, 221`) — sends the next `JoinRequest` with an empty target, which is then refused. A reprovision destroys a working worker you cannot rebuild while a second cluster exists |
| Second server fails to join (HA setup) | Token mismatch or etcd quorum issue | Check `journalctl -u k3s.service` on both servers; etcd needs majority to write |
| VIP doesn't fail over after primary loss | Single-server cluster, or `sdwan_vip_failover` blocked by `require_approval` | Add a second server; check approval queue |
| `kubectl` works but pods can't reach external services | Pods using flannel/CNI default route | Verify worker Nodes have proper egress. This is a pod *egress* concern, distinct from the encrypted pod-to-pod overlay (flannel-over-SDWAN, which ships per "Per-tenant pod plane" above). |
| Multiple clusters but `kubernetes_list_clusters` shows only one | Recent cluster decommissioning, or auth scope issue | Check `?include_decommissioned=true` filter; verify the account has access |

## How the System Concierge should use this

When an operator chats "set up prod and staging K3s" / "add a worker to staging cluster" / "decommission staging cluster":

1. For multi-cluster bootstrap, surface the Phase 1 + 2 sequence. Do **not** offer to add workers to a chosen cluster — say plainly that Phase 3 is not implemented and that k3s-agent joins are refused once a second cluster exists (see the banner at the top of this page)
2. For HA, propose Phase 4 (≥2 servers); use `request_confirmation` for the second-server provision
3. For decommission, use `kubernetes_decommission_cluster` with `request_confirmation` (destructive)
4. After each phase, surface the relevant cluster status from `kubernetes_get_cluster`

The Concierge filter includes `kubernetes_*` actions — this entire workflow is in scope.

## Related docs

- [`USE_CASE_MATRIX.md`](../USE_CASE_MATRIX.md) — use case 3 (multi-cluster K3s); use case 7 (hybrid persistent + ephemeral)
- [`CONTAINER_RUNTIMES.md`](../CONTAINER_RUNTIMES.md) — Phase 2 K3s lifecycle reference
- [`runbooks/node-provisioning.md`](./node-provisioning.md) — Node + NodeInstance lifecycle (each cluster member is a NodeInstance)
- [`runbooks/sdwan-network-setup.md`](./sdwan-network-setup.md) — SDWAN setup (required for cluster api_endpoint VIPs)
- [`SKILL_EXECUTORS.md`](../SKILL_EXECUTORS.md) — `provision_cluster` for one-shot multi-server cluster bootstrap; `sdwan_vip_failover`

---

_Last verified: 2026-06-03_
