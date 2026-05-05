# NodeInstance Use Case Compatibility Matrix

What works, what doesn't, and what to expect when running container workloads on Powernode-managed NodeInstances. Read this before designing your deployment.

This matrix exists because the platform's auto-registration plumbing is **bimodal-by-default** (long-lived persistent vs. tmpfs-wiped) but operators bring a spectrum of use cases. Here's the honest story for each.

## Quick Reference

| # | Use case | `lifecycle_class` | Modules | Status | Caveats |
|---|---|---|---|---|---|
| 1 | Long-lived edge gateway / SaaS tenant | `persistent` | `docker-engine` | ✅ Works | Don't terminate without backing up `/persist/var` |
| 2 | Single-cluster K3s for app workloads | `persistent` | `k3s-server` + `k3s-agent` | ✅ Works | Slice 3 (shipped): api_endpoint uses an SDWAN VIP — bootstrap node loss triggers VIP failover to next k3s-server holder |
| 3 | Multi-cluster K3s in one account | `persistent` | per cluster | ✅ Works | k3s-agent module assignment **MUST** carry `metadata.target_cluster_id` |
| 4 | Bursty batch jobs (ML, data pipelines) | `ephemeral` | `docker-engine` | ⚠️ Works with caveats | Bootstrap latency = ~90s per instance; consider pre-baked image |
| 5 | CI runner pool | `ephemeral` | `docker-engine` | ⚠️ Works with caveats | Image cache vaporizes on terminate; use a registry mirror |
| 6 | Multi-tenant container farm | `persistent` | `docker-engine` per tenant | ⚠️ Works with caveats | No host-level isolation; trust boundary is the SDWAN account |
| 7 | Hybrid (persistent control plane + ephemeral workers) | mixed | `k3s-server` persistent, `k3s-agent` ephemeral | ✅ Works | Workers can be cycled freely; control plane is the family heirloom |
| 8 | Cross-host Docker container networking | any | `docker-engine` | ❌ Not supported | No cross-host overlay; use K3s for orchestration |
| 9 | Pod-to-pod traffic encrypted via SDWAN | `persistent` | `k3s-*` | ❌ Not yet | Flannel uses host primary NIC; pod plane outside SDWAN |
| 10 | Workload-image CVE coverage | any | any | ❌ Not yet | CVE response covers NodeModules only; container images invisible |

## Detailed Walkthroughs

### Use Case 1 — Long-lived edge gateway / SaaS tenant ✅

**What you want**: a Docker host that runs nginx + your app for months. SSH-accessible. Containers survive reboot.

**Setup**:
```javascript
// Provision the instance
platform.system_provision_instance({
  template_id: "<template>",
  provider_region_id: "<region>",
  provider_instance_type_id: "<type>"
})
// Then via UI or MCP:
// - Set Node.lifecycle_class = "persistent" (default)
// - Attach Sdwan::Peer
// - Assign docker-engine module
```

**What works**:
- `/persist/var/lib/docker` survives reboot
- Containers with `--restart=always` come back after reboot
- Image cache survives reboot
- Platform's `docker_*` MCP actions work over SDWAN
- Reboot survives via `/persist/var`

**What to watch**:
- Termination ≠ reboot. When you `system_terminate_instance`, the underlying provider VM is destroyed and `/persist` goes with it. Back up first if you care about the data.
- The cascade FK (slice 1 hardening 2026-05-04) means `inst.destroy` cleanly cascade-deletes the managed `Devops::DockerHost` row + Vault TLS material.

### Use Case 2 — Single K3s cluster ✅

**What you want**: 1 control plane + 3 workers running app workloads. Use kubectl from anywhere on the SDWAN.

**Setup**:
```javascript
// 1. Provision 1 NodeInstance for control plane
//    - lifecycle_class: persistent (default)
//    - Attach SDWAN
//    - Assign k3s-server module
// 2. Wait ~90s for cluster bootstrap
//    Cluster appears in /app/devops/kubernetes
// 3. Provision N worker NodeInstances on same SDWAN
//    - Assign k3s-agent module
// 4. Download kubeconfig from UI
```

**What works**:
- Cluster bootstrap auto-registers via `phase=bootstrap` runtime/handshake
- Workers fetch join token via `phase=join_request`
- etcd state survives reboot in `/persist/var/lib/rancher/k3s/`
- kubectl works from anywhere on the SDWAN (api_endpoint = `https://[<bootstrap-node-/128>]:6443`)

**What to watch**:
- **Bootstrap node terminates cleanly** (slice 3 hardening). `KubernetesCluster.api_endpoint` points at an `Sdwan::VirtualIp` allocated at cluster bootstrap time. The bootstrap peer is the VIP's primary holder; subsequent `k3s-server` joiners (HA control plane) get added as `failover_holder_peer_ids` candidates. When the primary peer goes silent, the `sdwan_vip_failover` skill (or operator manual `system_sdwan_failover_virtual_ip`) promotes the next holder. kubectl + workers' K3S_URL keep working through the transition because the VIP address doesn't change. **Caveat**: the VIP fallback only works if you have 2+ `k3s-server` NodeInstances. A single-server cluster still loses connectivity when its only server dies (standard K8s assumption — control plane HA requires multiple servers).
- Pod-to-pod traffic uses flannel over the host primary NIC, NOT the SDWAN overlay. NetworkPolicy is your friend; physical isolation is not.
- Local-path PVCs don't migrate when pods reschedule. Plan your stateful workloads accordingly.

### Use Case 3 — Multi-cluster K3s ✅ (Phase 2.5)

**What you want**: prod + staging clusters in one account. Each NodeInstance joins a specific cluster.

**Setup** (Phase 2.5+):
```javascript
// Bootstrap two clusters separately:
//   - 1 NodeInstance assigned k3s-server (becomes Cluster A)
//   - Wait for cluster A to appear (~90s)
//   - 1 NodeInstance assigned k3s-server (becomes Cluster B)
//
// For each k3s-agent NodeInstance, set the assignment metadata:
platform.system_assign_module_to_template({
  template_id: "<worker-template>",
  module_name: "k3s-agent",
  config: { target_cluster_id: "<cluster-A-uuid>" }
})
```

**What works** (after slice 6):
- `KubernetesClusterProvisionerService.join_request!(target_cluster_id:)` resolves specifically
- Agent reads `target_cluster_id` from module assignment metadata at boot
- Agent passes through to `JoinRequest` HTTP body
- Platform validates cluster exists + is in the account + isn't in error state
- Empty/missing target_cluster_id → auto-select most recent active cluster (legacy single-cluster contract preserved)

**What to watch**:
- Agent must restart to pick up changes to `target_cluster_id` in module metadata.
- Cluster-level metadata for which clusters exist is operator-visible via `kubernetes_list_clusters`.

### Use Case 4 — Bursty batch jobs ⚠️

**What you want**: spin up 50 Docker hosts for an ML training run, terminate them when done.

**Reality**: this works, but bootstrap latency is the bottleneck.

**Setup**:
```javascript
// Set lifecycle_class on the Node before provisioning
//   Node.update!(lifecycle_class: "ephemeral")
// Provision 50 instances; each takes ~90s to be ready
// Run jobs across the fleet
// Terminate via system_terminate_instance — DockerHost rows + TLS material
//   cascade-delete via FK (slice 1 hardening)
```

**What works**:
- Cascade FK means clean teardown — no orphan rows
- Each instance's auto-registration is independent

**What to watch**:
- 90s × 50 = 75 minutes of cumulative bootstrap latency. For short batches, this dominates total runtime.
- **Workaround**: pre-bake a NodePlatform disk image with `docker-ce` already installed (Phase 1 disk image CI). Then bootstrap drops to ~30s.
- **Mitigation shipped (slice 7)**: pre-warmed instance pool — `System::InstancePool` keeps N warming/ready instances ready for atomic acquisition. Operators acquire via `system_acquire_pooled_instance` MCP action in <30s instead of 5-10min cold provision. Reaper auto-replenishes as members are claimed. See `system_create_instance_pool`, `system_acquire_pooled_instance`, `system_drain_instance_pool`.
- `lifecycle_class=ephemeral` is the right hint to the agent, but the agent reconciler short-circuit (skip expensive bootstrap) is **not yet implemented** — column exists, behavior change pending.

### Use Case 5 — CI runner pool ⚠️

**What you want**: a fleet of Docker hosts that pull build images, run jobs, get destroyed.

**Reality**: same as #4 plus the image cache problem.

**What to watch**:
- Image cache lives in `/persist/var/lib/docker` — gets vaporized on terminate. Every new instance pulls images cold. Use:
  - **Registry mirror** (Harbor, Gitea container registry) co-located on the SDWAN to reduce pull latency
  - **Pre-baked NodePlatform image** with common base images already in the docker storage layer
- Tag containers with `metadata.owner=ci_runner` when launching to differentiate from operator-run containers (provenance integration is Phase 2.5+ polish; for now the labels are advisory).

### Use Case 6 — Multi-tenant container farm ⚠️

**What you want**: each tenant gets a Docker host; they don't see each other.

**What works**:
- Each NodeInstance is its own Docker host
- TLS isolates daemon API access (each tenant's keys cover only their host)

**What to watch**:
- All hosts on the same SDWAN network can reach each other's daemon /128 endpoints (TLS-gated). For stronger isolation, put each tenant on a separate SDWAN network.
- **Trust boundary**: the SDWAN network's account ownership. If multiple tenants share an account, they share trust. Cross-account federation peers are the right primitive for true multi-tenant.

### Use Case 7 — Hybrid (persistent + ephemeral) ✅

**What you want**: long-lived K3s control plane + auto-scaling worker pool.

**Setup**:
```
Server NodeInstance:
  Node.lifecycle_class = "persistent"
  Module: k3s-server

Worker NodeInstances (N varies):
  Node.lifecycle_class = "ephemeral"
  Module: k3s-agent
  metadata.target_cluster_id = "<the-cluster-id>"
```

**What works**:
- Control plane survives forever; etcd state in `/persist/var/lib/rancher/k3s`
- Workers can be cycled freely; cluster reschedules pods automatically
- Cascade FK on `Devops::KubernetesNode` cleans up bookkeeping when instance terminates

### Use Case 8 — Cross-host Docker container networking ❌

**What you want**: container on host A talks directly to container on host B.

**Reality**: Docker default uses bridge networking. We don't set up cross-host overlay (Docker Swarm overlay networks). The platform doesn't ship a Docker Swarm cluster shape — the existing `swarm_*` MCP actions are for operator-registered Swarm clusters, not Powernode-managed ones.

**Workaround**: use K3s. K3s pods get pod networking via flannel (or Cilium in Phase 3) which handles cross-host transparently.

### Use Case 9 — Encrypted pod-to-pod via SDWAN ❌

**Reality**: K3s' default flannel CNI uses VXLAN over the host's primary NIC, not the SDWAN overlay. Pod-to-pod traffic between K3s nodes traverses whatever underlying network the hosts share.

**Future**: Phase 2 slice 9 (`pod_subnet_prefix` on `Sdwan::Network` + custom CNI) will route pod prefixes via the FRR iBGP daemon over SDWAN. Until then, treat pod plane as "not encrypted by Powernode."

**Mitigation**: for sensitive workloads, use NetworkPolicy + service mesh (Linkerd/Istio) on top of K3s for app-layer encryption.

### Use Case 10 — Workload-image CVE coverage ❌

**Reality**: the `cve_response` skill triages CVEs against `NodeModule` versions (the platform-distributed packages). Container images and Kubernetes pod images are invisible to the fleet sensor. A CVE in a pulled `nginx:1.21` image won't trip an alert.

**Future**: extend the CVE sensor to query `Devops::DockerImage.repo_digests` + (eventually) `Devops::KubernetesPod.image_digests` against the CVE feed.

**Mitigation**: scan container images at build time via your CI pipeline (Trivy, Grype). Pin versions; subscribe to upstream advisories.

## Anti-pattern Cheat Sheet

| If you... | You'll see... | Do this instead |
|---|---|---|
| Terminate the *only* K3s server (single-server cluster) | Cluster has no remaining api server; kubectl breaks | Add a 2nd k3s-server first; VIP failover handles transition |
| Run thousands of short-lived ephemeral instances | High bootstrap latency tax | Pre-bake disk image OR pre-warmed pool via `system_create_instance_pool` (slice 7 shipped) |
| Expect pod traffic encrypted via SDWAN | Plain VXLAN over host NIC | Use NetworkPolicy + service mesh until pod_subnet_prefix lands |
| Multi-cluster without `target_cluster_id` | k3s-agent joins the wrong cluster | Set `metadata.target_cluster_id` on the module assignment |
| SSH directly to managed Docker host and run containers | Platform sync imports them with `owner=operator` (advisory tag) | OK but track ownership via container labels |
| Backup `/persist` before terminating an instance | (no automated path yet) | Run a `docker save` / etcd snapshot before `system_terminate_instance` |

## Lifecycle Class Decision Tree

```
Will this instance be alive for >24 hours?
├── Yes, with state I care about
│       └── lifecycle_class: persistent (default)
│           tmpfs_store: false (default)
│           Use cases: 1, 2, 3, 6, 7-server
│
├── Yes, but state can be wiped on reboot
│       └── lifecycle_class: persistent
│           tmpfs_store: true
│           Edge use case: long-lived appliance with no local state
│
├── Hours-to-days, replaceable
│       └── lifecycle_class: ephemeral
│           tmpfs_store: true
│           Use cases: 4, 5, 7-worker
│
└── Provider-side spot/preemptible
        └── lifecycle_class: spot
            tmpfs_store: true
            Reapers prune bookkeeping aggressively
```

## How the System Concierge Should Use This

When an operator chats "I want to run X", the System Concierge should:

1. Identify which use case row best matches the request
2. Surface the **Status** column verdict: ✅ supported, ⚠️ supported with caveats, ❌ not yet
3. For ⚠️: show the relevant caveats before the operator commits
4. For ❌: explain why + suggest the closest supported alternative
5. For the chosen use case: drive the setup workflow via MCP tools (assign module, etc.)

This matrix is designed to be ingested into the System Concierge's RAG context — it's structured for that purpose.

## Related Docs

- `CONTAINER_RUNTIMES.md` — operator workflow for Phase 1 Docker + Phase 2 K3s
- `SKILL_EXECUTORS.md` — `docker_provision`, `provision_cluster` skills
- `FLEET_SENSORS.md` — what triggers fleet autonomy actions
- `ARCHITECTURE.md` — 8 subsystems including container runtimes
