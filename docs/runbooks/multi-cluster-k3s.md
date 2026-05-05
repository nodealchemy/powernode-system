# Multi-cluster K3s Runbook

Operator guide for running multiple K3s clusters in one account: bootstrap, agent targeting via `metadata.target_cluster_id`, HA control plane via slice 3 VIP failover, kubeconfig retrieval, and cross-cluster operator workflows.

**Audience:** operators running multi-environment fleets (prod + staging, multi-region, multi-tenant); SREs managing K3s upgrades.

## When to use multi-cluster

Multi-cluster is the right architecture when:

- You need **environment isolation** (prod vs staging) — separate clusters means independent upgrade cadences and failure domains
- You're running **multi-region** workloads — a cluster per region keeps API latency low
- You're providing **multi-tenant** Kubernetes-as-a-service — one cluster per tenant means clean trust boundaries
- You need **independent K3s versions** across workloads

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
  module_name: "k3s-server"
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
  module_name: "k3s-server"
})

// Wait ~90s, then:
platform.kubernetes_list_clusters()
// → { clusters: [
//      { id: "cluster-prod-id",    name: "k3s-prod-server-1",    status: "active" },
//      { id: "cluster-staging-id", name: "k3s-staging-server-1", status: "active" }
//    ] }
```

Two clusters now exist; their `api_endpoint` VIPs are different `/128` addresses.

## Phase 3 — Add workers to a specific cluster ⚠️

This is the critical step. Without `metadata.target_cluster_id`, agents auto-select the **most recent active cluster**, which means new workers will join the wrong cluster if you have multiples.

```javascript
// Provision a worker NodeInstance
platform.system_provision_instance({ node_id: "<worker-node-id>", ... })

// Assign k3s-agent WITH explicit target_cluster_id
platform.system_assign_module_to_template({
  template_id: "<worker-template>",
  module_name: "k3s-agent",
  config: {
    target_cluster_id: "cluster-prod-id"          // ← REQUIRED for multi-cluster
  }
})
```

The agent reads `target_cluster_id` from its module assignment metadata at boot, passes it through to the platform's `runtime/handshake` POST, and the platform's `KubernetesClusterProvisionerService.join_request!` validates:

1. The cluster with that ID exists
2. The cluster is in the same account as the requesting agent
3. The cluster is in `active` (not `error` or `decommissioning`) state

If any check fails, the join is rejected and the agent retries on the next reconcile.

**What to watch:**

- **Agent must restart** to pick up changes to `target_cluster_id` in module metadata. If you change a worker's target cluster mid-life, terminate + reprovision.
- **Empty `target_cluster_id`** falls back to "join most recent active cluster" — preserves single-cluster contract for legacy templates.
- Slice 6 hardened the validation; before slice 6, mismatched IDs silently joined the wrong cluster.

## Phase 4 — HA control plane (≥2 servers) ✅

Slice 3 enables VIP-backed HA: when the primary `k3s-server` goes silent, the VIP fails over to the next `k3s-server` holder. **Requires ≥2 server NodeInstances**.

```javascript
// Provision a second k3s-server bound to the same cluster
platform.system_create_node({ hostname: "k3s-prod-server-2", ... })
platform.system_provision_instance({ node_id: "<node-2-id>", ... })
platform.system_sdwan_attach_peer({ network_id: "<sdwan-net>", node_instance_id: "<instance-id>" })

// Assign k3s-server WITH target_cluster_id (this server JOINS, doesn't create)
platform.system_assign_module_to_template({
  template_id: "<k3s-server-template>",
  module_name: "k3s-server",
  config: {
    target_cluster_id: "cluster-prod-id"
  }
})

// Wait ~120s for the second server to join etcd. Verify:
platform.kubernetes_list_nodes({ cluster_id: "cluster-prod-id" })
// → { nodes: [
//      { instance_id: "...", role: "control-plane", status: "ready" },
//      { instance_id: "...", role: "control-plane", status: "ready" }
//    ] }
```

The second server is now a VIP failover candidate. `Sdwan::VirtualIp.failover_holder_peer_ids` includes its peer ID.

**Verify failover behavior:**

```javascript
// Dry-run a VIP failover to see who would be promoted
platform.system_sdwan_failover_virtual_ip({
  virtual_ip_id: "<cluster-vip-id>",
  dry_run: true
})
// → { resolved: false, dry_run: true, current_holder: <peer-1>, candidates: [{ peer: <peer-2>, score: 0.92 }, ...] }
```

`sdwan_vip_reachability_sensor` automatically fires `sdwan.vip_holder_silent` when the primary is silent, and `sdwan_vip_failover` skill (require_approval policy) handles promotion.

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
platform.kubernetes_get_cluster({ id: "cluster-prod-id" })

// List nodes in a cluster (control-plane + workers)
platform.kubernetes_list_nodes({ cluster_id: "cluster-prod-id" })

// Decommission an entire cluster (cascades to all member nodes)
platform.kubernetes_decommission_cluster({ cluster_id: "cluster-staging-id" })
// → cascade-deletes all member KubernetesNode rows; underlying NodeInstances are NOT terminated
```

For per-cluster module rolling upgrades, scope by template:

```javascript
// Upgrade k3s-server module across cluster-prod only
platform.execute_skill({
  skill: "system-rolling-module-upgrade",
  inputs: {
    template_id: "<k3s-prod-server-template>",     // scopes to cluster-prod's servers
    module_id: "mod-k3s-server",
    target_version_id: "v-k3s-1.31.0",
    batch_pct: 50,                                  // smaller batches for control plane
    max_consecutive_failures: 1
  }
})
```

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
  module_name: "k3s-server",
  config: { target_cluster_id: "<existing-cluster-id>" }
})
// → second server joins etcd; cluster goes from 1-replica to 3-replica (etcd default)
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| New worker joins the wrong cluster | `target_cluster_id` not set or stale | Set `metadata.target_cluster_id` on the agent's module assignment; reprovision the worker |
| Worker stuck in `join_request` phase | API endpoint VIP unreachable | Verify worker is on the same SDWAN network as the cluster's bootstrap server |
| Worker stuck in `join_request`, "bad token" | Token rotated since last cache | Restart `powernode-agent` on the worker; or re-fetch via terminate + reprovision |
| Second server fails to join (HA setup) | Token mismatch or etcd quorum issue | Check `journalctl -u k3s.service` on both servers; etcd needs majority to write |
| VIP doesn't fail over after primary loss | Single-server cluster, or `sdwan_vip_failover` blocked by `require_approval` | Add a second server; check approval queue |
| `kubectl` works but pods can't reach external services | Pods using flannel/CNI default route | Verify worker Nodes have proper egress; not an SDWAN issue (slice 9 doesn't cover pod plane yet) |
| Multiple clusters but `kubernetes_list_clusters` shows only one | Recent cluster decommissioning, or auth scope issue | Check `?include_decommissioned=true` filter; verify the account has access |

## How the System Concierge should use this

When an operator chats "set up prod and staging K3s" / "add a worker to staging cluster" / "decommission staging cluster":

1. For multi-cluster bootstrap, surface the Phase 1 + 2 sequence; emphasize that `target_cluster_id` is required for workers
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
