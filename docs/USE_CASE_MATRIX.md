# NodeInstance Use Case Compatibility Matrix

> Status: active

What works, what doesn't, and what to expect when running container workloads on Powernode-managed NodeInstances. Read this before designing your deployment.

This matrix exists because the platform's auto-registration plumbing is **bimodal-by-default** (long-lived persistent vs. tmpfs-wiped) but operators bring a spectrum of use cases. Here's the honest story for each.

## Quick Reference

| # | Use case | `lifecycle_class` | Modules | Status | Caveats |
|---|---|---|---|---|---|
| 1 | Long-lived edge gateway / SaaS tenant | `persistent` | `docker-engine` | ✅ Works | Don't terminate without backing up `/persist/var` |
| 2 | Single-cluster K3s for app workloads | `persistent` | `k3s-server` + `k3s-agent` | ✅ Works | api_endpoint is an SDWAN VIP whose only holder is the bootstrap server. Losing that server is an outage, not a failover: K3s HA is **parked** — a 2nd `k3s-server` bootstraps a separate cluster (which then refuses worker joins), and the datastore is SQLite via kine, not etcd. See [Use Case 2](#use-case-2--single-k3s-cluster-) |
| 3 | Multi-cluster K3s in one account | `persistent` | per cluster | ❌ Not implemented | Bootstrapping a second cluster works; placing a worker in a chosen one does not — the join is refused (`AmbiguousClusterError`, 409) and no node is produced. See [Use Case 3](#use-case-3--multi-cluster-k3s--not-implemented) |
| 4 | Bursty batch jobs (ML, data pipelines) | `ephemeral` | `docker-engine` | ⚠️ Works with caveats | Bootstrap latency = ~90s per instance; consider pre-baked image |
| 5 | CI runner pool | `ephemeral` | `docker-engine` | ⚠️ Works with caveats | Image cache vaporizes on terminate; use a registry mirror |
| 6 | Multi-tenant container farm | `persistent` | `docker-engine` per tenant | ⚠️ Works with caveats | No host-level isolation; trust boundary is the SDWAN account |
| 7 | Hybrid (persistent control plane + ephemeral workers) | mixed | `k3s-server` persistent, `k3s-agent` ephemeral | ✅ Works | Workers can be cycled freely; control plane is the family heirloom |
| 8 | Cross-host Docker container networking | any | `docker-engine` | ❌ Not supported | No cross-host overlay; use K3s for orchestration |
| 9 | Pod-to-pod traffic encrypted via SDWAN | `persistent` | `k3s-*` | ✅ Works (opt-in) | Set `pod_subnet_prefix` on the `Sdwan::Network`; flannel host-gw over WireGuard (shipped 2026-05-19). Default (null) = plain VXLAN on host NIC |
| 10 | Workload-image CVE coverage | any | any | ❌ Not yet | CVE response covers NodeModules only; container images invisible |

### How `lifecycle_class` is actually set

The `lifecycle_class` column above is the class a use case *wants*. It is not a
knob an operator turns — and since IMP-19843220ac68 it is not a column the
platform fills in either. `system_nodes.lifecycle_class` is being **retired**:
it is now nullable with no default, and both application paths that used to
write it have stopped, so a Node created today carries `NULL`. The class of a
machine lives on the `System::InstancePool` that produced it.

| Withdrawn claim | What is actually true |
|---|---|
| "Set `Node.lifecycle_class` via the UI or MCP" | No API surface accepts it. `system_create_node` declares eight parameters and `system_update_node` nine (eight mutable attributes plus the `node_id` selector); `lifecycle_class` is not among either; REST `node_params` (`nodes_controller.rb:96`) permits `name, description, enabled, node_template_id, worker_id, public_address, allocate_public_ip, ssh_key, ssh_host_key, config`, and create and update share that ONE list — so "not settable at create" and "not changeable later" are the same fact. Undeclared MCP keys are dropped without an error, so the wrong call succeeds. |
| "`Node.update!(lifecycle_class: ...)` from the Rails console" | Succeeds at the DB level and changes no observable anywhere. |
| "Read it back to confirm" | Nothing emits it. `serialize_node` returns `id, name, template_id, worker_id, ssh_key_fingerprint, ssh_key_type, enabled, created_at`; `serialize_node_full` adds four more, none of them this. No serializer under `server/app/serializers/` mentions the column. |
| "Filter a node listing by `lifecycle_class`" | `system_list_nodes` declares exactly one FILTER parameter, `template_id` (plus the shared `limit`/`cursor` page controls), and `list_nodes` has exactly one where-clause. A filter key you pass is dropped silently and you get the unfiltered list back with no error. |
| "It is unset until you set it" | It is unset on every new Node — the DB default was removed rather than made settable. Before the retirement it was `persistent` on every Node by DB default, which is the opposite mistake and was the one the docs used to make. |

**No path sets it any more.** Until the retirement,
`System::InstancePoolService#provision_warming_member!` created each pool
member's Node with `lifecycle_class: pool.lifecycle_class` — unattended, on a
60s cron (`System::InstancePoolReplenisherJob`) over every active *or draining*
pool (draining pools are no longer topped up — IMP-cb2da06a384b)
— and `PlatformDeploymentOrchestrator` wrote the literal `"persistent"`, which
was the DB default and so moved nothing. Both writes are gone. Stopping them
required removing the default in the same change: a pool member is `ephemeral`
or `spot` by construction (`System::InstancePool` is CHECK-constrained to those
two), so leaving a NOT NULL `persistent` default behind would have turned an
unread column into a confidently wrong one. The `example_multi_tenant` dev seed
still writes the column directly, defaulted to `persistent`; it is not an
operator path and goes when the column is dropped.

**Nothing reads it** — which is why it was retired rather than wired. No
consumer of a *Node's* `lifecycle_class` exists in `server/`, `extensions/`,
`worker/` or the Go agent; the agent bootstrap short-circuit it was added for
was never implemented, and if one is ever built it must read the pool, not the
Node: the copy was a snapshot taken at member-create time, and rotating a pool's
class afterwards (GitOps `apply_pool` "update" carries it) never refreshed it.
A member Node reaches its pool through `config["instance_pool_id"]`. The column,
its CHECK constraint and its index survive one deploy window and are then
dropped. One same-named column
survives elsewhere: `system_instance_pools.lifecycle_class` (`ephemeral|spot`,
default `ephemeral`) is a DIFFERENT field with a different value set — the code
has already tripped over that. A third column on `system_node_instances` used to
share the name and no longer does: IMP-1e2e7b43b083 renamed it to `lease_class`,
because `task_scoped` answers "why was this instance leased", a different axis
rather than a narrower value set.

So: the class of a machine is a property of the `System::InstancePool` you
create it from (`system_create_instance_pool`, then
`system_acquire_pooled_instance`) — that column is settable, readable and
rotatable. On a Node there is no route, and no route that changes an observable:
a direct `update!` writes a column nothing reads and that is on its way out.

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
// - WITHDRAWN: "Set Node.lifecycle_class = persistent". There is no UI or MCP
//   surface that accepts it, and the column is retired — nullable, no default,
//   no writer — so there is nothing to do and nothing to record. See "How
//   lifecycle_class is actually set" above.
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
//    - lifecycle_class: persistent (retired column — not settable, nothing to do)
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
- The datastore is **SQLite via kine, not etcd**: the server is installed with a bare `INSTALL_K3S_EXEC=server` — no `--cluster-init`, no `--datastore-endpoint` — which is K3s' single-server default. K3s writes it to `/var/lib/rancher/k3s/` — a SQLite database, the join `token` and `server/tls/`, not an etcd member. (The layout under that directory — `server/db/state.db` and friends — is upstream K3s', not this platform's; nothing in this repo pins it, so check it against your k3s version)
- **Do not assume that path is durable across a reboot.** This document used to say it resolved into `/persist/var/lib/rancher/k3s/` via the agent's `/var` bind mount; nothing in this tree establishes that. `mount.EnsurePersistentVar` is the only code that binds `/var` onto `/persist/var` and it has **no production caller** — `agent/internal/runtime/softreboot.go:143-148` says so verbatim — and every path the agent itself relies on to survive a reboot is written as an absolute `/persist/var/...`. Whether `/var` is durable is a boot-image property of your node; check it before treating k3s state as persistent, and take the backup in the [Anti-pattern Cheat Sheet](#anti-pattern-cheat-sheet) either way
- kubectl works from anywhere on the SDWAN (api_endpoint = `https://[<bootstrap-node-/128>]:6443`)

**What to watch**:
- **Losing the bootstrap server is an outage, not a failover** — K3s HA is **parked**. `KubernetesCluster.api_endpoint` points at an `Sdwan::VirtualIp` allocated at cluster bootstrap time with the bootstrap peer as its *only* holder: `allocate_api_vip!` (`kubernetes_cluster_provisioner_service.rb:744`) sets `failover_holder_peer_ids = []`. Two writers can touch that column — `add_to_vip_failover_candidates!` (`:473`, body `:628`) and `refresh_vip_holder!` (`:647`, reached only from `update_credentials!` (`:613`), whose only caller is `bootstrap!`'s same-`node_instance_id` idempotency arm at `:137`) — but neither is reachable from a *second server joining this cluster*, because no such join exists: the install is a bare `INSTALL_K3S_EXEC=server` with no `--server`/`--token` (`shell_applier.go:121`), `BootstrapConfig.InstallArgs()` emits CNI args only, the one K3S_URL/K3S_TOKEN writer (`WriteJoinConfig`) exists on the *agent* applier alone, and `server_manager.go` never calls `JoinRequest`. A second `k3s-server` NodeInstance therefore runs `bootstrap!`, whose idempotency check keys on `node_instance_id` (`:135`), and creates a **second cluster** — which is exactly what makes every later `k3s-agent` join refuse with `AmbiguousClusterError` (see Use Case 3). So `sdwan_vip_failover` / `system_sdwan_failover_virtual_ip` have nothing to promote, and when the only server dies kubectl and the workers' `K3S_URL` stay down until *that* server is restored. Parked, not queued: HA would need `--cluster-init` on the first server, which changes how every already-provisioned cluster bootstraps.
- Pod-to-pod traffic uses flannel over the host primary NIC, NOT the SDWAN overlay. NetworkPolicy is your friend; physical isolation is not.
- Local-path PVCs don't migrate when pods reschedule. Plan your stateful workloads accordingly.

This section used to describe an HA control plane and an etcd datastore. Neither exists; the claims are kept visible so an operator who planned around them can recognise them:

| Withdrawn claim | What is actually true |
|---|---|
| "bootstrap node loss triggers VIP failover to next k3s-server holder" | There is no next holder. The VIP is allocated with the bootstrap peer as sole holder and an empty `failover_holder_peer_ids`. The two writers of that column (`add_to_vip_failover_candidates!`, `refresh_vip_holder!`) are only ever reached for a cluster the calling node already belongs to, and no second server ever joins an existing one. Bootstrap node loss is an outage until that node is restored. |
| "subsequent `k3s-server` joiners (HA control plane) get added as `failover_holder_peer_ids` candidates" | No `k3s-server` ever joins an existing cluster — a second one bootstraps a separate cluster. `add_to_vip_failover_candidates!` (`:628`) runs from `register_node_join!`, which resolves membership from the agent's own `bootstrappedFor` id — the *new* cluster, where that server is already the primary holder — so it returns without touching the first cluster's VIP. |
| "the VIP fallback only works if you have 2+ `k3s-server` NodeInstances" | You cannot have 2+ `k3s-server` NodeInstances in one cluster. The second is a second cluster, and its existence refuses every later worker join (`AmbiguousClusterError`, 409). |
| "Add a 2nd k3s-server first; VIP failover handles transition" | The former Anti-pattern remedy, and the operation that manufactures the outage it claims to prevent: it creates a second cluster and refuses subsequent worker joins. Restore the bootstrap node instead — see the [Anti-pattern Cheat Sheet](#anti-pattern-cheat-sheet). |
| "etcd state survives reboot in `/persist/var/lib/rancher/k3s/`" | Wrong twice. The datastore is SQLite via kine, not an etcd member — no Go or Ruby source passes `--cluster-init` or `--datastore-endpoint`. And k3s writes to `/var/lib/rancher/k3s/`, not `/persist/...`: the `/var` → `/persist/var` bind that sentence assumed (`mount.EnsurePersistentVar`) has no production caller, so this document no longer asserts that k3s state survives a reboot. |
| "resolves into `/persist/var/lib/rancher/k3s/` via the agent's EnsurePersistentVar bind mount" | The `k3s-server` module description made the same claim (`server/db/seeds/k3s_modules.rb`) and it is corrected there too. `mount.EnsurePersistentVar` exists but is called only by its own test; `agent/internal/runtime/softreboot.go:143-148` records that `/var` is not a bind mount on a current node and that "the durable /var bind" as written elsewhere in this tree describes an unused code path. |
| "Control plane survives forever; etcd state in `/persist/var/lib/rancher/k3s`" | Same correction, in Use Case 7: SQLite, not etcd — and one server, so its loss is an outage. |
| "Run a `docker save` / etcd snapshot before `system_terminate_instance`" | There is no etcd to snapshot. Stop k3s and copy `/var/lib/rancher/k3s/server/` (`db/` and `token`) — upstream K3s' documented single-server (SQLite) backup. |

### Use Case 3 — Multi-cluster K3s ❌ NOT IMPLEMENTED

**What you want**: prod + staging clusters in one account. Each NodeInstance joins a specific cluster.

**Reality**: bootstrapping the second cluster works. Placing a worker in a
chosen one does not, and the second cluster's existence breaks worker joins
for *both*. `target_cluster_id` is wired on the platform side and unreachable
from the agent, so every worker's `JoinRequest` carries an empty target; with
more than one non-error cluster in the account the platform **refuses** it —
`AmbiguousClusterError`, with `system.k3s_ambiguous_cluster_join_refused`
emitted at severity `high` (`kubernetes_cluster_provisioner_service.rb:329`)
and 409 returned. The worker does not join the wrong cluster; **no node is
produced at all**. Do not go looking for a misplaced node; there is none.

**What is actually wired** — the platform half, and only that half:
- `KubernetesClusterProvisionerService.join_request!(target_cluster_id:)` resolves a supplied value specifically, and validates the cluster exists, is in the account, and isn't in `error` state
- `handle_join_request` forwards `params[:target_cluster_id].presence` into it (`runtime_handshake_handlers.rb:164`), so a value that arrived would be honoured
- Nothing supplies one on the join. `k3sd.AgentManager.TargetClusterID` is declared and consumed (`JoinRequest(ctx, m.TargetClusterID)`) but never written, and `k3sd.ModulesAPI` is `AssignedModules(ctx) ([]string, error)` — module **names** only — so assignment config never reaches the K3s reconcilers
- The one value that *does* travel is not a choice. On `phase=ready` the agent sends `cluster_id` — the cluster it already joined — and `handle_k3s_ready` forwards it as `target_cluster_id` (`runtime_handshake_handlers.rb:195`) so a ready re-fire cannot relocate an already-joined node. That is a memory of a join, not a way to pick one, and it is empty on the first join that matters here

The producer is tracked separately (IMP-a5f236e8cc56 gap 3). Until it lands,
**Use Case 2 (single cluster) is the supported shape**: with exactly one
non-error cluster the join is unambiguous and succeeds without a target. If
you need workers on cluster A, add them **before** cluster B exists — there is
no operator-side workaround afterwards.

**Withdrawn setup** — the assignment call below still succeeds and still
stores the value; it just never reaches the node:

```javascript
// WITHDRAWN — stored, not delivered. See the table below.
platform.system_assign_module_to_template({
  template_id: "<worker-template>",
  // The template-assignment verbs take the NodeModule UUID, not its name — system_list_modules returns { id, name }.
  module_id: "<k3s-agent-module-id>",
  config: { target_cluster_id: "<cluster-A-uuid>" }
})
```

| Withdrawn claim | What is actually true |
|---|---|
| "k3s-agent module assignment **MUST** carry `metadata.target_cluster_id`" | Required by the platform, and impossible to supply from the agent. Setting it on the assignment changes nothing about the join. |
| "Agent reads `target_cluster_id` from module assignment metadata at boot" | There is no such read, and no channel for one: `ModulesAPI` hands the K3s reconcilers module **names** only. The **server** half is real — a value that arrived would be honoured — which is what "wired on one side only" means here. |
| "Agent passes through to `JoinRequest` HTTP body" | `JoinRequest` is called with `m.TargetClusterID`, a field the constructor never sets, so the body always carries an empty target. |
| "Empty/missing target_cluster_id → auto-select most recent active cluster (legacy single-cluster contract preserved)" | There is no most-recent-active fallback for a multi-cluster account. `resolve_membership_cluster!` (`kubernetes_cluster_provisioner_service.rb:351`) auto-selects **only when there is exactly one candidate**; with more than one it raises. "Candidate" is `where.not(status: "error")`, so a cluster in `pending`, `bootstrapping`, `degraded` or `disconnected` counts toward the ambiguity, not just an `active` one. |
| "Agent must restart to pick up changes to `target_cluster_id` in module metadata" | Nothing to pick up. A restart, terminate + reprovision, or `system_refresh_instance_modules` all leave the join target empty. |

**What to watch**:
- Which clusters exist in the account is operator-visible via `kubernetes_list_clusters` — and the count is what decides whether worker joins are refused.

### Use Case 4 — Bursty batch jobs ⚠️

**What you want**: spin up 50 Docker hosts for an ML training run, terminate them when done.

**Reality**: this works, but bootstrap latency is the bottleneck.

**Setup**:
```javascript
// WITHDRAWN — "Set lifecycle_class on the Node before provisioning":
//   Node.update!(lifecycle_class: "ephemeral")
// succeeds at the DB level and changes nothing. No API surface accepts the
// field, nothing reads a Node's copy of it, and no serializer returns it.
// To get ephemeral Nodes: create an InstancePool with
// lifecycle_class: "ephemeral" via system_create_instance_pool, then take
// members with system_acquire_pooled_instance — which is the pre-warmed pool
// this section already recommends below, and the only route there is.
// See "How lifecycle_class is actually set" above.
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
- WITHDRAWN — "`lifecycle_class=ephemeral` is the right hint to the agent". It is not a hint to anything: `lifecycle_class` appears nowhere under `agent/` and no node-facing payload carries it, so the value never leaves the database. The agent reconciler short-circuit (skip expensive bootstrap) it was added for is **not yet implemented** — column exists, behavior change pending, and no channel to deliver it if it shipped.

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
  Node.lifecycle_class = "persistent"   # retired column — nothing to set
  Module: k3s-server

Worker NodeInstances (N varies):
  # WITHDRAWN as an instruction — never something you assign, and since the
  # column's retirement not something a pool member carries either: the class
  # lives on the InstancePool. See "How lifecycle_class is actually set" above.
  Node.lifecycle_class = "ephemeral"
  Module: k3s-agent
  # WITHDRAWN — stored, never delivered. Nothing on the agent reads it and the
  # join always carries an empty target. See Use Case 3.
  metadata.target_cluster_id = "<the-cluster-id>"
```

**What works**:
- Control plane state — the SQLite datastore (kine, not etcd), certs and tokens — lives in `/var/lib/rancher/k3s`. It is one server: its loss is an outage, not a failover, and this document no longer claims that path is reboot-durable (see Use Case 2)
- Workers can be cycled freely; cluster reschedules pods automatically
- Cascade FK on `Devops::KubernetesNode` cleans up bookkeeping when instance terminates

### Use Case 8 — Cross-host Docker container networking ❌

**What you want**: container on host A talks directly to container on host B.

**Reality**: Docker default uses bridge networking. We don't set up cross-host overlay (Docker Swarm overlay networks). The platform doesn't ship a Docker Swarm cluster shape — the existing `swarm_*` MCP actions are for operator-registered Swarm clusters, not Powernode-managed ones.

**Workaround**: use K3s. K3s pods get pod networking via flannel (or Cilium in Phase 3) which handles cross-host transparently.

### Use Case 9 — Encrypted pod-to-pod via SDWAN ✅ (opt-in)

**Reality**: K3s' default flannel CNI uses VXLAN over the host's primary NIC. **Opt-in encryption via SDWAN overlay** (shipped 2026-05-19): set `pod_subnet_prefix` on the `Sdwan::Network`; the platform then stamps the cluster's bootstrap config with `--flannel-iface=wg-sdwan-<handle>`, `--flannel-backend=host-gw`, `--cluster-cidr=<pod_subnet_prefix>` at install time so pod-to-pod traffic flows through the existing WireGuard tunnels via the AllowedIPs covering the SDWAN /64. **No double-encapsulation** (host-gw mode injects direct kernel routes; the WG tunnels do the encryption work). ovn-Kubernetes ignores `pod_subnet_prefix` and uses its own pod-network layer.

**Default posture**: when `pod_subnet_prefix` is null (default), flannel falls back to VXLAN on host primary NIC — same as pre-2026-05-19 behavior. Operators must explicitly set the field per network to opt in.

**Operator path**: create the SDWAN network with `pod_subnet_prefix: "10.42.0.0/16"` (or any non-overlapping RFC1918 CIDR), then bootstrap k3s with `cni_plugin: "flannel"` on that network. See [`CONTAINER_RUNTIMES.md` §"CNI selection — Routing pod traffic over SDWAN"](./CONTAINER_RUNTIMES.md#routing-pod-traffic-over-sdwan-pod_subnet_prefix--shipped-2026-05-19).

**Additional mitigation** (orthogonal): use NetworkPolicy + service mesh (Linkerd/Istio) on top of K3s for app-layer authorization between pods. This feature secures the *transport* between nodes; mesh policies enforce *authorization* between pods.

### Use Case 10 — Workload-image CVE coverage ❌

**Reality**: the `cve_response` skill triages CVEs against `NodeModule` versions (the platform-distributed packages). Container images and Kubernetes pod images are invisible to the fleet sensor. A CVE in a pulled `nginx:1.21` image won't trip an alert.

**Future**: extend the CVE sensor to query `Devops::DockerImage.repo_digests` + (eventually) `Devops::KubernetesPod.image_digests` against the CVE feed.

**Mitigation**: scan container images at build time via your CI pipeline (Trivy, Grype). Pin versions; subscribe to upstream advisories.

## Anti-pattern Cheat Sheet

| If you... | You'll see... | Do this instead |
|---|---|---|
| Terminate the *only* K3s server (single-server cluster) | Cluster has no remaining api server; kubectl breaks and stays broken until that server is back | **Do not add a 2nd `k3s-server`** — it bootstraps a separate cluster (K3s HA is parked), and that second cluster refuses every later worker join. Restore the bootstrap node: start it again if it is stopped. If the VM is gone, the cluster is gone with it, but its row is not — `mark_node_stopped!` leaves the cluster counting as a join candidate — so hard-delete the dead row with `kubernetes_decommission_cluster` *before* bootstrapping a replacement server (restore `/var/lib/rancher/k3s/server/` from backup onto it if you need the old state), or worker joins are refused again |
| Run thousands of short-lived ephemeral instances | High bootstrap latency tax | Pre-bake disk image OR pre-warmed pool via `system_create_instance_pool` (slice 7 shipped) |
| Expect pod traffic encrypted via SDWAN | Plain VXLAN over host NIC (the default when `pod_subnet_prefix` is null) | Set `pod_subnet_prefix` on the `Sdwan::Network` before bootstrapping with `cni_plugin: "flannel"` — shipped 2026-05-19, see [Use Case 9](#use-case-9--encrypted-pod-to-pod-via-sdwan--opt-in) |
| Bootstrap a second cluster in an account that still needs k3s-agent workers | Every subsequent worker join is refused — 409 `AmbiguousClusterError`, `system.k3s_ambiguous_cluster_join_refused` at severity `high`, and no node produced | No workaround today; add the workers before the second cluster exists. See [Use Case 3](#use-case-3--multi-cluster-k3s--not-implemented) |
| SSH directly to managed Docker host and run containers | Platform sync imports them with `owner=operator` (advisory tag) | OK but track ownership via container labels |
| Backup `/persist` before terminating an instance | (no automated path yet) | Docker hosts: `docker save`. K3s servers: there is no etcd to snapshot — the datastore is SQLite — so stop k3s and copy `/var/lib/rancher/k3s/server/` (`db/` and `token`) before `system_terminate_instance` |

## Lifecycle Class Decision Tree

```
Will this instance be alive for >24 hours?
├── Yes, with state I care about
│       └── lifecycle_class: persistent (the do-nothing case; the column is
│           retired, so nothing records it)
│           tmpfs_store: false (default)
│           Use cases: 1, 2, 3, 6, 7-server
│
├── Yes, but state can be wiped on reboot
│       └── lifecycle_class: persistent (also the do-nothing case; the column
│           is retired, so nothing records it)
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

**Reading the tree**: it maps a use case to a class, not a setting you apply.
`persistent` is the do-nothing CASE, not a do-nothing VALUE — nothing records
it any more, so a machine you simply create carries no class at all.
`ephemeral` and `spot` come from creating the machine out of a
`System::InstancePool` with that `lifecycle_class` — on the pool, which is the
row that carries the class. The Node column that used to mirror it is retired
(nullable, no default, no writer).
`tmpfs_store` is in the SAME position and the tree should not be read as setting
it either: no MCP verb or REST parameter accepts it, `System::Node#enable_tmpfs!`
/ `#disable_tmpfs!` (`server/app/models/system/node.rb` — named, not
line-cited, because the previous `node.rb:81-87` citation had drifted ~46 lines)
are called only from specs, and its one non-spec writer is a smoke seed writing
the default `false`. See "How `lifecycle_class` is actually set" above.

## How the System Concierge Should Use This

When an operator chats "I want to run X", the System Concierge should:

1. Identify which use case row best matches the request
2. Surface the **Status** column verdict: ✅ supported, ⚠️ supported with caveats, ❌ not yet
3. For ⚠️: show the relevant caveats before the operator commits
4. For ❌: explain why + suggest the closest supported alternative
5. For the chosen use case: drive the setup workflow via MCP tools (assign module, etc.)
6. For cross-cutting topology design (SDWAN composition — host bridges, OVN logical networks, IPFIX collectors), delegate to the **System Topology Designer** via `execute_agent` rather than composing it inline. The Concierge frames the operator's intent; the specialist returns the topology plan. See the System extension `CLAUDE.md` §"AI Agents" for the agent split.

This matrix is designed to be ingested into the System Concierge's RAG context — it's structured for that purpose.

## Related Docs

- [`CONTAINER_RUNTIMES.md`](./CONTAINER_RUNTIMES.md) — operator workflow for Phase 1 Docker + Phase 2 K3s
- [`SKILL_EXECUTORS.md`](./SKILL_EXECUTORS.md) — `docker_provision`, `provision_cluster` skills
- [`FLEET_SENSORS.md`](./FLEET_SENSORS.md) — what triggers fleet autonomy actions
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — 8 subsystems including container runtimes

_Last verified: 2026-09-03_
