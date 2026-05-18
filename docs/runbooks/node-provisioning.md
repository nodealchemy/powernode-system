# Node Provisioning Runbook

Step-by-step operator guide for the full Node + NodeInstance lifecycle: from "I have a Template" through "the instance is decommissioned and rows cleaned up." Includes per-state error recovery and the LocalQemuProvider variant for offline / smoke-test environments.

**Audience:** external operators (open-source consumers), internal Powernode operators, on-call SREs handling stuck instances.

## Quick reference

| Phase | What happens | Typical duration | MCP entry point |
|---|---|---|---|
| 1. Create Node | Logical row representing a future-or-existing host | <1 s | `system_create_node` |
| 2. Provision instance | Provider boots a VM with the netboot image | 30 s – 10 min | `system_provision_instance` |
| 3. Bootstrap | Agent installs, mTLS handshake, module reconcile | ~90 s cold (5-10 min on slow providers) | none — agent-driven |
| 4. Run | Heartbeats, reconcile loop, task lease | indefinite | `system_get_instance` |
| 5. Drain | Workloads relocated, services stopped | 1-30 min | `system_drain_instance` |
| 6. Decommission | Provider VM destroyed, FK cascades fire | <1 min | `system_terminate_instance` |

## Lifecycle diagram

```
  ┌──────────────┐
  │ no instance  │  Node row exists; no provider VM yet
  └──────┬───────┘
         │ system_provision_instance
         ▼
  ┌──────────────┐  Task: pending → provisioning
  │ provisioning │  Provider creates VM; netboot fetches kernel + initramfs
  └──────┬───────┘
         │ first heartbeat from agent
         ▼
  ┌──────────────┐  Agent: enrolling (CSR → mTLS)
  │ bootstrapping│  Modules pulled, fs-verity verified, composefs mounted
  └──────┬───────┘
         │ module reconcile complete + handshake POST
         ▼
  ┌──────────────┐  Task: running
  │   running    │  Heartbeats every 30s; task lease ready
  └──────┬───────┘
         │ system_drain_instance (graceful) │
         ▼                                  │ system_terminate_instance (hard)
  ┌──────────────┐                          │
  │   draining   │ Workloads cordoned + relocated; services stopped
  └──────┬───────┘                          │
         │                                  │
         ▼                                  ▼
  ┌──────────────────────────────────────────────────┐
  │              terminated                          │
  │  Cascade FKs: Devops::DockerHost / KubernetesNode│
  │  cleanup, Vault TLS revoked, Sdwan::Peer removed │
  └──────────────────────────────────────────────────┘
```

## Phase 1 — Create Node ✅

The `Node` is a logical row. No provider resources are touched here.

```javascript
platform.system_create_node({
  account_id: "<account-id>",                     // current account by default
  hostname: "edge-tokyo-01",                      // human-readable
  node_template_id: "tmpl-edge-base",             // composes assigned modules
  node_platform_id: "platform-ubuntu-2404-amd64", // disk image family
  node_architecture_id: "arch-amd64",             // kernel + boot binaries
  lifecycle_class: "persistent",                  // "persistent" | "ephemeral" | "spot"
  metadata: {                                     // optional; surfaces in dashboard
    "owner": "edge-team",
    "purpose": "tokyo-cdn-edge"
  }
})
// → { node: { id, hostname, status: "no_instance", ... } }
```

**What to watch:**
- `lifecycle_class` is **immutable after first instance provisions** (per `feedback_local_qemu_default_test_target` memory). Choose carefully: `persistent` for control-plane / database / SaaS tenant; `ephemeral` for batch / CI / replaceable workers; `spot` for provider-preemptible workloads.
- `node_template_id` determines which modules will be assigned at bootstrap. To reuse an existing fleet template, query first: `platform.system_list_templates`.
- A `Node` with no `NodeInstance` is harmless — bookkeeping only.

## Phase 2 — Provision NodeInstance ✅

```javascript
platform.system_provision_instance({
  node_id: "<node-id>",
  provider_region_id: "region-aws-us-east-1",   // or "region-local-qemu"
  provider_instance_type_id: "type-t3-medium",  // or "type-qemu-2cpu-4gb"
  // Optional:
  spot: false,
  ssh_key_ids: ["<key-id>"]   // injected via fw-cfg metadata for break-glass
})
// → { instance: { id, status: "provisioning", task_id, ... } }
```

The platform creates a `Task` (status=`pending`), enqueues a worker job, and returns immediately. The worker runs the provider's `provision_instance!` adapter:

- **AWS / GCP / Azure / OpenStack** — provider-specific API calls; takes 30 s – 5 min
- **LocalQemuProvider** — libvirt domain creation with direct kernel boot from M3 artifacts; takes ~10-30 s in `real` mode, instant in `recorder` mode (per `project_local_qemu_provider` memory)

Status transitions: `pending → provisioning → running` (via Task AASM).

**Verify provisioning:**

```javascript
platform.system_get_instance({ id: "<instance-id>" })
// → { instance: { status: "provisioning", task_id, last_heartbeat_at: null, ... } }

// Or watch the task progress:
platform.system_get_task({ id: "<task-id>" })
```

**What to watch:**
- Provider quota: most providers throttle bulk provisioning. For >10 instances, use `provision_cluster` skill (hard cap 50/call) or sequence calls with `system_create_instance_pool` (slice 7) for warm capacity.
- `MissingNetbootImageError`: the platform-side disk image hasn't been published to OCI yet. Run `system_list_disk_image_publications` to confirm the publication exists with `status=published`.
- LocalQemuProvider: ensure `POWERNODE_LIBVIRT_MODE=real` and `POWERNODE_IMAGE_BASE` points at `extensions/system/initramfs/build`. See [`SMOKE_TEST.md`](../SMOKE_TEST.md).

## Phase 3 — Bootstrap ✅

The provider VM POSTs to `runtime/handshake` once the kernel boots:

1. **Identity discovery** — agent reads from `cmdline` / `virtio-fw-cfg` / cloud metadata; selects the appropriate `IdentityStrategy`
2. **Enrollment** — agent generates Ed25519 keypair, POSTs CSR to `/api/v1/system/node_api/enrollment` with bootstrap token; receives signed mTLS cert
3. **Module pull** — agent fetches OCI artifacts for assigned modules from `registry.example.com` registry; verifies `cosign` signatures + fs-verity digests
4. **Mount union root** — composefs lower layer + tmpfs (or `/persist`) overlay; `pivot_root` into composed userspace
5. **Service start** — `systemctl start powernode-agent.service`; agent posts `phase=ready` heartbeat

The platform marks the instance `status=running` after the first `phase=ready` POST.

**What to watch:**
- Bootstrap timeline: ~90 s from kernel boot to `phase=ready` on warm cache; +30-60 s on first run when modules aren't cached. Slice 7 instance pools cut this to <30 s by pre-warming.
- Stuck in `bootstrapping`: usually a module pull failure (signature verify, network, OCI 404). Check `journalctl -u powernode-agent` on the node, or `platform.recent_events` for the instance.
- Bootstrap token rotation: tokens expire 24 h after issue. Re-provision if you see `BootstrapTokenExpiredError`.

## Phase 4 — Run ✅

The instance heartbeats every 30 s. Per-tick:
- Agent posts heartbeat (uptime, version, last reconcile result)
- Platform refreshes `last_heartbeat_at`
- `instance_status_sensor` runs every 60 s; fires `instance.silent` if no heartbeat in 5 min (default)
- Module reconciler walks assigned modules; pulls + verifies + mounts updates if module versions changed
- Task lease: agent claims any pending tasks for this instance via `worker_api/tasks` and runs them

**Verify health:**

```javascript
platform.system_get_instance({ id: "<instance-id>" })
// → { instance: {
//      status: "running",
//      last_heartbeat_at: "2026-05-04T13:42:01Z",
//      running_module_digests: { "system-base": "sha256:abc...", ... },
//      ...
//    }}

platform.system_drift_report({ instance_id: "<instance-id>" })
// → { drift: false } or { drift: true, attach: [...], detach: [...], update: [...] }
```

If `drift: true`, the `module_drift_sensor` will emit `module.drift_detected`; Fleet Autonomy auto-runs `drift_remediate` (notify_and_proceed policy) on next tick.

## Phase 5 — Drain (graceful) ⚠️

For `persistent` instances running workloads (Docker daemon, K3s server), prefer drain over hard terminate:

```javascript
platform.system_drain_instance({
  id: "<instance-id>",
  timeout_seconds: 600,           // give workloads up to 10 min to relocate
  cordon_only: false              // false → also stop services after cordon
})
// → { task_id, status: "draining" }
```

Drain coordinates with Devops layer:
- **DockerHost**: `docker stop` containers tagged `--restart=always` first; then daemon shutdown
- **KubernetesNode (k3s-agent)**: `kubectl cordon` + `kubectl drain --ignore-daemonsets`
- **k3s-server bootstrap node**: triggers slice 3 VIP failover before stopping the API server

**What to watch:**
- Pod relocation requires capacity on remaining nodes — drain can stall if cluster is at capacity. Add capacity first or accept partial drain.
- Local-path PVCs don't migrate; pods using them go pending. Plan stateful workload placement accordingly.
- Single-server K3s clusters cannot drain the only server — kubectl loses access. Either add a second `k3s-server` first, or hard-terminate.

## Phase 6 — Decommission ✅

```javascript
platform.system_terminate_instance({ id: "<instance-id>" })
// → { task_id, status: "terminating" }
```

Cascade actions (FK + service-level):
- Provider VM destroyed via the same provider adapter that created it
- `Devops::DockerHost` (if managed) destroyed; Vault TLS material revoked
- `Devops::KubernetesNode` (if k3s-*) destroyed
- `Sdwan::Peer` rows for this instance removed (slice 9 cleanup callback)
- `Sdwan::VirtualIp` failover triggered if this instance was a holder (slice 3)
- `NodeCertificate` rows revoked
- `BootstrapToken` rows expired

**The `Node` row remains** by design — re-provisioning into the same logical Node preserves history and audit chain. Delete the Node explicitly via `system_delete_node` only if it's truly retired.

## Per-state error recovery

| Stuck in… | Likely cause | Recovery |
|---|---|---|
| `pending` (>5 min) | Worker queue stalled or provider quota | Check `platform.recent_events` for `provider_quota_exceeded`; restart worker via `sudo systemctl restart powernode-worker@default`; retry |
| `provisioning` (>10 min) | Provider API timeout, libvirt domain creation hung | `platform.system_cancel_task({ id: "<task-id>" })`; investigate provider; retry with `system_provision_instance` |
| `bootstrapping` (>5 min after first heartbeat) | Module pull failure | SSH to node (if SDWAN attached) → `journalctl -u powernode-agent` shows the failed module + reason; common: cosign signature mismatch, OCI 404, network |
| `running` but no heartbeats >5 min | Network partition or agent crash | `platform.recent_events` for `instance.silent`; SSH or console-access via libvirt; manual restart of `powernode-agent.service` |
| `draining` (>30 min) | Pods can't reschedule (capacity) | Add capacity, or hard-terminate with explicit `force: true` |
| `terminating` (>5 min) | Provider VM teardown stuck | Check provider console; in worst case, mark task `failed` via `system_cancel_task` and clean orphan rows |

For all stuck states, use `attribute_failure` skill to enumerate recent module/version changes that may have caused the failure:

```javascript
platform.execute_skill({
  skill: "system-attribute-failure",
  inputs: { instance_id: "<instance-id>", lookback_hours: 24 }
})
// → { candidates: [...], top_candidate: {...}, confidence: "medium", reasoning: "..." }
```

## LocalQemuProvider variant (smoke / dev)

For offline development or CI smoke tests, use the LocalQemuProvider:

```bash
# Prerequisites: libvirt, dracut, qemu-bridge-helper, Go toolchain
# Build M3 artifacts first:
cd extensions/system/initramfs && ./build.sh

# Run the smoke seed (provisions one NodeInstance to multi-user.target):
cd server && \
  POWERNODE_LIBVIRT_MODE=real \
  POWERNODE_IMAGE_BASE=../extensions/system/initramfs/build \
  bundle exec rails runner \
    "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_provision.rb')"
```

The seed creates: 1 Account → 1 Node (lifecycle_class=persistent) → 1 NodeInstance via LocalQemuProvider, watches the AASM Task progression, and reports the kernel boot pipeline through to multi-user.target. Total runtime: ~15 min on cold boot (TCG without `/dev/kvm`); ~3 min with KVM.

LocalQemuProvider modes:
- `real` — actual libvirt domain creation + QEMU/KVM boot (default for smoke)
- `recorder` — records what the libvirt adapter *would* do (fast; no VM)
- `disabled` — skips provider entirely; useful for unit tests

Switch via `POWERNODE_LIBVIRT_MODE=real|recorder|disabled`.

## How the System Concierge should use this

When an operator chats "I want to add a node" / "provision a new instance" / "decommission edge-tokyo-01":

1. Identify the requested phase (create / provision / drain / decommission)
2. Surface the relevant MCP action(s) + required inputs (template, region, instance type)
3. For destructive actions (drain, terminate), use `request_confirmation` skill before invoking
4. After invoking, watch the Task AASM transitions and report status changes back to the operator
5. If status hangs, surface the "Per-state error recovery" guidance for the relevant stuck state

The Concierge has 4 read-shape skills useful here: `capacity_recommend` (for "do I need more nodes?"), `attribute_failure` (for "why did instance X fail?"), `runbook_generate` (for template-specific runbooks), `cve_runbook_generate` (when provisioning is blocked by a CVE).

## Related docs

- [`USE_CASE_MATRIX.md`](../USE_CASE_MATRIX.md) — 10 NodeInstance use cases with status badges
- [`CONTAINER_RUNTIMES.md`](../CONTAINER_RUNTIMES.md) — Phase 1 Docker + Phase 2 K3s lifecycle (depends on this runbook for instance provisioning)
- [`runbooks/sdwan-network-setup.md`](./sdwan-network-setup.md) — attach SDWAN peer (required for managed runtimes)
- [`runbooks/instance-pool-tuning.md`](./instance-pool-tuning.md) — pre-warmed pools (slice 7) for ephemeral workloads
- [`SMOKE_TEST.md`](../SMOKE_TEST.md) — LocalQemuProvider smoke test setup
- `db/seeds/smoke_test_provision.rb` — canonical provisioning seed
