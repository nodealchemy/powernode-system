# Example 02 — K3s cluster with SDWAN

End-to-end walkthrough: bootstrap a K3s cluster, attach SDWAN, join 2 workers, retrieve kubeconfig. Uses the existing `smoke_test_k3s_runtime.rb` seed (platform-side test; doesn't actually boot K3s).

**Goal:** validate the K3s control-plane + worker provisioning chain (slice 3 VIP failover + Phase 2 K3s).

**Audience:** developers + Kubernetes-focused operators new to Powernode.

**Prerequisites:**
- Example 01 working (LocalQemuProvider end-to-end)
- SDWAN module catalog seed loaded (`sdwan_overlay_module.rb`, `k3s_modules.rb`)

## Step 1 — Run the K3s smoke seed

```bash
cd server

bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_runtime.rb')"
```

The seed (platform-side only — no actual K3s install):
1. Creates a Node + bootstrap NodeInstance with `k3s-server` module assigned
2. Attaches SDWAN peer to the bootstrap instance
3. Simulates `phase=bootstrap` POST → creates `Devops::KubernetesCluster`
4. Allocates an `Sdwan::VirtualIp` for `api_endpoint` (slice 3)
5. Provisions a 2nd Node + NodeInstance, attaches SDWAN, simulates `phase=join_request` → adds `KubernetesNode` row
6. Verifies cluster `status=active`, kubeconfig retrievable
7. Runs idempotency + decommission cascade tests

Total runtime: ~30 s (no actual VM boot).

## Step 2 — Inspect the cluster via MCP

```bash
# List clusters
platform.kubernetes_list_clusters
# → {
#      clusters: [{
#        id: "cluster-abc-123",
#        name: "smoke-k3s",
#        flavor: "k3s",
#        status: "active",
#        api_endpoint: "https://[fd00:abcd:1::100]:6443",
#        node_count: 2
#      }]
#    }

# List cluster nodes
platform.kubernetes_list_nodes({ cluster_id: "cluster-abc-123" })
# → {
#      nodes: [
#        { instance_id: "...", role: "control-plane", status: "ready" },
#        { instance_id: "...", role: "worker",        status: "ready" }
#      ]
#    }

# Retrieve kubeconfig
platform.kubernetes_get_kubeconfig({ cluster_id: "cluster-abc-123" })
# → { kubeconfig: "apiVersion: v1\n...", api_endpoint: "https://[fd00:abcd:1::100]:6443" }
```

## Step 3 — Production variant (real K3s, not smoke)

For a real K3s cluster (post-Example 01 working):

```javascript
// 1. Create the bootstrap server template
platform.system_create_node({ hostname: "k3s-server-1", node_template_id: "<k3s-server-template>", ... })
platform.system_provision_instance({ node_id, ... })

// 2. Attach SDWAN (REQUIRED for slice 3 VIP)
platform.system_sdwan_attach_peer({
  network_id: "<sdwan-network>",
  node_instance_id: "<bootstrap-instance-id>"
})

// 3. Assign k3s-server module
platform.system_assign_module_to_template({
  template_id: "<k3s-server-template>",
  module_name: "k3s-server"
})

// 4. Wait ~90s for cluster bootstrap
platform.kubernetes_list_clusters()
// → cluster appears with status=active

// 5. Provision worker
platform.system_create_node({ hostname: "k3s-worker-1", node_template_id: "<k3s-worker-template>", ... })
platform.system_provision_instance({ node_id, ... })
platform.system_sdwan_attach_peer({ network_id, node_instance_id })

platform.system_assign_module_to_template({
  template_id: "<k3s-worker-template>",
  module_name: "k3s-agent",
  config: { target_cluster_id: "<cluster-id>" }   // explicit target prevents wrong-cluster join
})
```

## Step 4 — Use the cluster

```bash
# Save kubeconfig
platform.kubernetes_get_kubeconfig({ cluster_id }) | jq -r '.kubeconfig' > ~/.kube/k3s.yaml

# Use kubectl over SDWAN
kubectl --kubeconfig ~/.kube/k3s.yaml get nodes
# Operator must be on the same SDWAN network or have a federation route
```

## Step 5 — Cleanup

```javascript
platform.kubernetes_decommission_cluster({ cluster_id: "<cluster-id>" })
// → cascade-deletes KubernetesNode rows; underlying NodeInstances NOT terminated

platform.system_terminate_instance({ id: "<bootstrap-instance>" })
platform.system_terminate_instance({ id: "<worker-instance>" })
```

## What to watch

- **VIP failover requires ≥2 servers** — single-server cluster loses connectivity if its only server dies
- **`metadata.target_cluster_id` is mandatory** in multi-cluster accounts (per [`runbooks/multi-cluster-k3s.md`](../runbooks/multi-cluster-k3s.md))
- **Kubeconfig requires SDWAN reachability** — use a federation peer or VPN bootstrap for off-network operators
- **Pod-to-pod traffic is unencrypted** — flannel uses host primary NIC, not SDWAN (use case 9 in [`USE_CASE_MATRIX.md`](../USE_CASE_MATRIX.md))

## Related

- [`runbooks/multi-cluster-k3s.md`](../runbooks/multi-cluster-k3s.md) — multi-cluster patterns
- [`runbooks/sdwan-network-setup.md`](../runbooks/sdwan-network-setup.md) — SDWAN setup
- [`CONTAINER_RUNTIMES.md`](../CONTAINER_RUNTIMES.md) — Phase 2 K3s lifecycle reference
- `db/seeds/smoke_test_k3s_runtime.rb` — seed source
