# Multi-cluster K3s Runbook

> Status: active

Operator guide for running multiple K3s clusters in one account: bootstrap, VIP-backed `api_endpoint`, kubeconfig retrieval, and cross-cluster operator workflows. An HA control plane (Phase 4) and placing workers in a chosen cluster (Phase 3) are **not implemented** — see the banner below.

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
> **Phase 4 (HA control plane) is NOT IMPLEMENTED either — now confirmed.** An
> earlier revision of this banner reported that as an unverified suspicion. It
> has since been verified at HEAD: a second `k3s-server` has no join path
> (`WriteJoinConfig` is defined only on `ShellAgentApplier`, and
> `BootstrapConfig.InstallArgs` has no seam for `--server` / `--token`), so it
> bootstraps a **second cluster** instead of extending the first — which is
> exactly what trips the refusal above for every worker you add afterwards.
> **An operator following this page in order manufactures the failure it warns
> about.** Workers can only be added while the account holds exactly one
> cluster, and both Phase 2 (bootstrap cluster B) and Phase 4 end that window
> permanently. Add every worker you need first; the phase numbering is not a
> safe execution order.
>
> Unlike Phase 3, Phase 4 is **not** queued behind IMP-a5f236e8cc56. K3s HA is
> **parked**: the platform does not do this, and there is no work scheduled to
> make it. The reason is the useful part — the first server bootstraps without
> `--cluster-init`, so its datastore is not etcd and could not accept a second
> control-plane member even if a join path existed. Supporting HA would mean
> changing how *every already-provisioned cluster* bootstraps, which is why it
> is parked rather than queued. Plan single-server clusters, not an HA
> migration. The withdrawn steps are kept visible in
> [Phase 4](#phase-4--ha-control-plane-2-servers--not-implemented), alongside
> what each of them actually does.

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
| "The agent reads `target_cluster_id` from its module assignment metadata at boot, passes it through to the platform's `runtime/handshake` POST" | The **server** half is real: `handle_join_request` forwards `params[:target_cluster_id].presence` into `join_request!` (`runtime_handshake_handlers.rb:164`), so a value that arrived would be honoured. The **agent** half does not exist. `k3sd.AgentManager.TargetClusterID` is declared (`agent_manager.go:53`) and consumed (`agent_manager.go:158`, passed to `JoinRequest`) but never written: `NewAgentManager` takes five arguments — client, modules, applier, nodeID, onError — none of them a cluster, and its struct literal sets six fields, not including this one. Nor is there a channel that could carry it: `k3sd.ModulesAPI` is `AssignedModules(ctx) ([]string, error)`, module **names** only, so assignment config never reaches the K3s reconcilers. Every worker's `JoinRequest` therefore sends an empty target. |
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

## Phase 4 — HA control plane (≥2 servers) ❌ NOT IMPLEMENTED

**A second `k3s-server` does not join the first cluster. It bootstraps a second
cluster.** Assigning `k3s-server` to a second NodeInstance is not an HA
operation — it is a second bootstrap. And because the Phase 3 refusal counts
clusters, **running this phase is what makes every later worker join fail.**
This page lists Phase 3 before Phase 4, but the causal dependency runs the
other way: the phase numbering is not a safe execution order. Add every worker
you need while the account still holds exactly one cluster.

Three facts, each verified in code:

1. **No join path exists.** `k3sd.ServerManager` never calls `JoinRequest` and
   never references `TargetClusterID` — it calls `Bootstrap` and then reports
   ready against its own `bootstrappedFor` cluster (`server_manager.go:193,
   215`). The only writer of `K3S_URL` / `K3S_TOKEN` is `WriteJoinConfig`,
   defined on `ShellAgentApplier` (`shell_applier.go:318`), the *worker*-side
   applier. The `ServerApplier` interface (`applier.go:140`) has no equivalent
   method at all.
2. **The install has no seam for one.** `ShellServerApplier.InstallK3sServer`
   runs `curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=server sh -s -` plus
   whatever `BootstrapConfig.InstallArgs()` returns (`applier.go:81`), and that
   emits CNI / flannel-overlay flags only — its `default:` arm returns
   `nil, false`. There is no path for `--server`, `--token`, or
   `--cluster-init`.
3. **The platform then creates a new cluster row.** `bootstrap!`'s idempotency
   check keys on `node_instance_id`
   (`kubernetes_cluster_provisioner_service.rb:135`), so a *different*
   NodeInstance falls straight through and a second cluster is created —
   `Devops::KubernetesCluster.create!(status: "bootstrapping")` with its own
   VIP, a `KubernetesNode` with `role: "server"`, and `node_count: 1`
   (`:227`, `:242`, `:252`).

**K3s HA is parked, not pending.** Phase 3 is a missing write awaiting a
producer (IMP-a5f236e8cc56); Phase 4 is not, and no work is scheduled to make
it. Even with a join path wired up a second server could not join: the first
server bootstraps **without `--cluster-init`**, so its datastore is SQLite, not
embedded etcd, and there is no etcd cluster to accept a second control-plane
member. (The `BootstrapConfig` doc comment in `agent/internal/k3sd/applier.go`
says the same — a zero-value config is the upstream default with a SQLite via
kine datastore — and the exec string in fact 2 is what runs.) Supporting HA
would therefore change how **every already-provisioned cluster** bootstraps,
which is why it is parked rather than queued. Design for single-server
clusters; do not plan around a future migration to HA.

The steps below are **withdrawn**, kept visible so you can recognise them if
you have already run them:

```javascript
// WITHDRAWN — this does not add a server to cluster-prod-id. It bootstraps a
// second, independent cluster, and that is what makes every later k3s-agent
// join refuse. See Phase 3.
platform.system_create_node({ hostname: "k3s-prod-server-2", ... })
platform.system_provision_instance({ node_id: "<node-2-id>", ... })
platform.system_sdwan_attach_peer({ network_id: "<sdwan-net>", node_instance_id: "<instance-id>" })

platform.system_assign_module_to_template({
  template_id: "<k3s-server-template>",
  module_id: "<k3s-server-module-id>"
  // config: { target_cluster_id } is stored and never delivered — the same
  // missing channel as Phase 3 (`ModulesAPI` hands over module names only),
  // and the k3s-server reconciler has no join path that could use it anyway.
})

// WITHDRAWN — this listing returns one node, not two. The new server is the
// sole node of a different cluster; `kubernetes_list_clusters` is where it
// shows up.
platform.kubernetes_list_nodes({ cluster_id: "cluster-prod-id" })
```

| Withdrawn claim | What is actually true |
|---|---|
| "Wait ~120s for the second server to join etcd" | Nothing joins, at any timeout. `ServerManager` runs the same bootstrap path the first server ran, and `bootstrap!` creates a new `Devops::KubernetesCluster` because its idempotency check keys on `node_instance_id` (`kubernetes_cluster_provisioner_service.rb:135`). |
| "The second server is now a VIP failover candidate" | Not for cluster A's VIP. `add_to_vip_failover_candidates!` (`kubernetes_cluster_provisioner_service.rb:628`) runs from `register_node_join!`, which resolves membership from the agent's own cached `bootstrappedFor` id — the *new* cluster, where this server is already the primary holder, so the call returns without adding anything. Cluster A's `failover_holder_peer_ids` is unchanged. |
| "the second server joins etcd; the existing cluster keeps running" | The existing cluster does keep running, and is untouched. But adding HA mid-life is not an online operation, because it is not an HA operation. |
| "cluster goes from 1-replica to 3-replica (etcd default)" | Neither cluster is an etcd cluster. Without `--cluster-init` the k3s server uses its SQLite datastore; there are no replicas to count. |

**What still works.** Single-server clusters are unaffected, and the VIP
machinery itself is real — the api_endpoint is a VIP, `sdwan_vip_failover` and
`system_sdwan_failover_virtual_ip` behave as documented, and
`sdwan_vip_reachability_sensor` fires `system.sdwan_vip_unreachable` when the
holder goes silent. What is missing is a second candidate to fail over *to*:
with one server per cluster, `failover_holder_peer_ids` stays empty and
promotion has nowhere to go.

**Inspect the VIP (still accurate, single-holder):**

```javascript
platform.system_sdwan_get_virtual_ip({ virtual_ip_id: "<cluster-vip-id>" })
// → { virtual_ip: { id, holder_peer_ids: [<the one server>],
//                   failover_holder_peer_ids: [], primary_holder_peer_id, ... } }

// Manual failover promotes the head of failover_holder_peer_ids to holder.
// Single required param: virtual_ip_id (no dry-run / scoring mode). With an
// empty candidate list there is nothing to promote.
platform.system_sdwan_failover_virtual_ip({ virtual_ip_id: "<cluster-vip-id>" })
```

## Phase 5 — Get kubeconfig per cluster ✅

```javascript
platform.kubernetes_get_kubeconfig({ cluster_id: "cluster-prod-id" })
// → {
//      kubeconfig: "apiVersion: v1\nclusters:\n  - cluster:\n      server: https://[fd00:abcd:1::100]:6443\n      certificate-authority-data: ...\n  ...",
//      api_endpoint: "https://[fd00:abcd:1::100]:6443"
//    }
```

The `api_endpoint` is the slice 3 VIP. kubectl traffic goes to the VIP rather than the server's own address, so the address in your kubeconfig does not change if the cluster is ever rebuilt onto a new bootstrap node.

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

**This is not an anti-pattern you can avoid — it is the only shape available.**
VIP failover would need ≥2 servers in one cluster, and [Phase 4](#phase-4--ha-control-plane-2-servers--not-implemented)
cannot produce that, so every cluster is single-server:

- ✅ Works for development / staging / small workloads
- ❌ Cannot survive bootstrap-node loss — `kubectl` and worker `K3S_URL` connectivity break the moment the only server dies
- ❌ Has the VIP allocated, but with an empty candidate list there is nothing to promote, so failover raises rather than switching

**If you start with single-server, you stay single-server.** There is no
supported way to add a second control-plane node — see
[Phase 4](#phase-4--ha-control-plane-2-servers--not-implemented), where the
mid-life "add HA" snippet below is withdrawn and each of its claims is set
against what actually happens. Plan around the limitation: treat loss of the
bootstrap node as a cluster rebuild, not a failover, and size the blast radius
accordingly.

Do **not** rely on the `/persist/var/lib/rancher/k3s/` durability story that
other pages in this tree describe. `mount.EnsurePersistentVar` — the bind mount
that story depends on — has no production caller (`agent/internal/mount/bind.go:16`;
`agent/internal/runtime/softreboot.go:143-148` says so in as many words), so
`/var` is not a bind mount on a current node. Whether k3s state actually
survives a given reboot is unverified here; do not plan around it either way.

```javascript
// WITHDRAWN — "adding HA mid-life". This does not extend the existing
// cluster; it bootstraps a second one. See the Phase 4 withdrawal table.
platform.system_provision_instance({ node_id: "<new-server-node>", ... })
platform.system_sdwan_attach_peer({ ... })
platform.system_assign_module_to_template({
  template_id: "<existing-server-template>",
  module_id: "<k3s-server-module-id>"
  // config: { target_cluster_id } withdrawn — not delivered; see Phase 4
})
// → a second cluster, holding one node. The original cluster is unchanged,
//   and every later k3s-agent join is now refused (Phase 3).
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Worker does not join at all, `system.k3s_ambiguous_cluster_join_refused` (severity `high`) in the event stream | Two or more non-error clusters in the account. The join carries no `target_cluster_id` because nothing on the agent supplies one, and the platform refuses rather than guessing | Expected outcome, not a misconfiguration. There is no fix today — see [Phase 3](#phase-3--add-workers-to-a-specific-cluster--not-implemented). Do not go looking for a misplaced node; none was created |
| Worker stuck in `join_request` phase | API endpoint VIP unreachable | Verify worker is on the same SDWAN network as the cluster's bootstrap server |
| Worker stuck in `join_request`, "bad token" | Token rotated since last cache | Restart `powernode-agent` on the worker; or re-fetch via terminate + reprovision. **⚠️ In a multi-cluster account, do not terminate + reprovision.** Once joined, the worker keeps working because it re-reports readiness against its own cached `joinedClusterID` (`agent_manager.go:177, 198`), which the platform accepts as the target. Anything that clears that cache — cleanup, a stop, or a k3s reinstall (`agent_manager.go:153, 219, 228`) — sends the next `JoinRequest` with an empty target, which is then refused. A reprovision destroys a working worker you cannot rebuild while a second cluster exists |
| Second `k3s-server` never shows up in `kubernetes_list_nodes` for the first cluster | It never tried to join. The k3s-server reconciler has no join path, so it bootstrapped a second cluster instead | Expected outcome, not a misconfiguration — see [Phase 4](#phase-4--ha-control-plane-2-servers--not-implemented). `kubernetes_list_clusters` will show the new server as the sole node of a new cluster. Nothing on the assignment changes this |
| VIP doesn't fail over after primary loss | Every cluster is single-server (Phase 4 is not implemented), so `failover_holder_peer_ids` is empty and there is nothing to promote; or `sdwan_vip_failover` is blocked by `require_approval` | Check the approval queue. If the cluster genuinely has one server, this is expected, and adding another server will not fix it — it makes a second cluster |
| `kubectl` works but pods can't reach external services | Pods using flannel/CNI default route | Verify worker Nodes have proper egress. This is a pod *egress* concern, distinct from the encrypted pod-to-pod overlay (flannel-over-SDWAN, which ships per "Per-tenant pod plane" above). |
| Multiple clusters but `kubernetes_list_clusters` shows only one | A cluster was decommissioned — that is a HARD delete, not a hidden row — or the caller is scoped to a different account | Nothing can un-hide it. Both decommission paths call `cluster.destroy!` (`server/app/services/ai/tools/kubernetes_provisioning_tool.rb`, `extensions/system/server/app/services/system/executors/runtime/decommission_k3s_cluster.rb`), `devops_kubernetes_clusters` has no soft-delete or archival column, and the member `devops_kubernetes_nodes` rows cascade away with it. What survives is the audit row: `Devops::KubernetesCluster` includes `Auditable`, whose `before_destroy` writes an `AuditLog` with `action: "deleted"`, `resource_type: "Devops::KubernetesCluster"`, `resource_id` set to the dead cluster id, and `old_values` carrying its name, slug, status, environment and node_count. Read it at `GET /api/v1/audit_logs?resource_type=Devops::KubernetesCluster` — account-scoped unless the caller holds `admin.audit.read`, and `resource_id` is **not** a supported filter, so filter on the type and read the id out of the payload. If no such row exists, nothing was decommissioned and this is account scope — check which account the token resolves to. The same hard delete is why a decommissioned cluster stops counting toward `AmbiguousClusterError`: the candidate set is a live `where(account_id:).where.not(status: "error")` query (`kubernetes_cluster_provisioner_service.rb`), which a destroyed row cannot enter |

### Withdrawn: the decommissioned-cluster filter ❌ NOT IMPLEMENTED

Kept visible, per this page's treatment of the Phase 3 and Phase 4 withdrawals,
so an operator who already tried it recognises what they ran.

| Withdrawn claim | What is actually true |
|---|---|
| "Check `?include_decommissioned=true` filter" | No such parameter exists on any cluster-listing surface, and nothing could back one. Decommission is a hard delete on both paths and the clusters table has no `deleted_at`, so there is no retained row for a filter to reveal. The surviving record is the `AuditLog` row described in the Troubleshooting table above |

## How the System Concierge should use this

When an operator chats "set up prod and staging K3s" / "add a worker to staging cluster" / "decommission staging cluster":

1. For multi-cluster bootstrap, surface the Phase 1 + 2 sequence. Do **not** offer to add workers to a chosen cluster — say plainly that Phase 3 is not implemented and that k3s-agent joins are refused once a second cluster exists (see the banner at the top of this page)
2. Do **not** propose an HA control plane. Say plainly that Phase 4 is not implemented: a second `k3s-server` bootstraps a second cluster rather than joining the first, and doing so refuses every subsequent worker join. If the operator asks for HA anyway, say that K3s HA is parked — not a queued defect and not on a roadmap — and steer the design to single-server clusters
3. For decommission, use `kubernetes_decommission_cluster` with `request_confirmation` (destructive)
4. After each phase, surface the relevant cluster status from `kubernetes_get_cluster`

The Concierge filter includes `kubernetes_*` actions — this entire workflow is in scope.

## Related docs

- [`USE_CASE_MATRIX.md`](../USE_CASE_MATRIX.md) — use case 3 (multi-cluster K3s); use case 7 (hybrid persistent + ephemeral)
- [`CONTAINER_RUNTIMES.md`](../CONTAINER_RUNTIMES.md) — Phase 2 K3s lifecycle reference
- [`runbooks/node-provisioning.md`](./node-provisioning.md) — Node + NodeInstance lifecycle (each cluster member is a NodeInstance)
- [`runbooks/sdwan-network-setup.md`](./sdwan-network-setup.md) — SDWAN setup (required for cluster api_endpoint VIPs)
- [`SKILL_EXECUTORS.md`](../SKILL_EXECUTORS.md) — `sdwan_vip_failover`. **Note:** `provision_cluster` provisions N instances of a template (up to 50); pointed at a `k3s-server` template that is N *clusters*, not one cluster of N servers — see [Phase 4](#phase-4--ha-control-plane-2-servers--not-implemented)

---

_Last verified: 2026-09-01 — Phases 3 and 4 re-verified against the agent and provisioner source; both withdrawn. Phases 1, 2, 5, 6 not re-verified in that pass._
