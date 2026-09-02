# Node Provisioning Runbook

> Status: active

Step-by-step operator guide for the full Node + NodeInstance lifecycle: from "I have a Template" through "the instance is decommissioned and rows cleaned up." Includes per-state error recovery and the LocalQemuProvider variant for offline / smoke-test environments.

**Audience:** external operators (open-source consumers), internal Powernode operators, on-call SREs handling stuck instances.

## Quick reference

| Phase | What happens | Typical duration | MCP entry point |
|---|---|---|---|
| 1. Create Node | Logical row representing a future-or-existing host | <1 s | `system_create_node` |
| 2. Provision instance | Provider boots a VM with the netboot image | 30 s – 10 min | `system_provision_instance` |
| 3. Bootstrap | Agent installs, mTLS handshake, module reconcile | ~90 s cold (5-10 min on slow providers) | none — agent-driven |
| 4. Run | Heartbeats, reconcile loop, task lease | indefinite | `system_get_instance` |
| 5. Drain | **Marker + FleetEvent only** — workloads keep running; relocation is manual | seconds (the call itself) | `system_drain_instance` |
| 6. Decommission | Provider VM destroyed, FK cascades fire | <1 min | `system_terminate_instance` |

## Lifecycle diagram

The `NodeInstance` AASM has **9 states**: `pending`, `provisioning`, `starting`,
`running`, `stopping`, `stopped`, `rebooting`, `terminated`, `error`. There is
**no `draining` state**, and `system_drain_instance` does not drive the instance
toward one: it records intent and changes no state at all (Phase 5 below).
`draining` is a `pool_state` on pooled instances — a different column, unrelated
to the `config["drain_*"]` markers — not an instance AASM state. There is also
**no `failed` state** — the terminal
failure state is `error`. The "bootstrapping" box below is the agent-driven boot
window *within* the `provisioning` state, not a separate AASM state.

```
  ┌──────────────┐
  │ (no instance)│  Node row exists; no provider VM yet
  └──────┬───────┘
         │ system_provision_instance
         ▼
  ┌──────────────┐  AASM: pending → mark_provisioning → provisioning
  │ provisioning │  Provider creates VM; netboot fetches kernel + initramfs
  └──────┬───────┘
         │  (agent boot window: enroll CSR → mTLS,
         │   modules pulled, fs-verity verified, erofs mounted)
         │                                   ╲  provider error / boot failure
         │ first phase=ready heartbeat        ╲  → mark_errored
         ▼                                     ▼
  ┌──────────────┐  AASM: mark_running    ┌──────────┐
  │   running    │  heartbeats every 30s  │  error   │ terminal failure
  └──────┬───────┘  task lease ready      └────┬─────┘ (no orphaned row)
         │                                      │ terminate
         │ system_terminate_instance (hard).    │ (allowed from error)
         │   stop/reboot also leave running.    │
         │   system_drain_instance does NOT —   │
         │   it records intent, changes nothing.│
         ▼                                       ▼
  ┌──────────────────────────────────────────────────┐
  │              terminated                          │
  │  Cascade FKs: Devops::DockerHost / KubernetesNode│
  │  cleanup, Vault TLS revoked, Sdwan::Peer removed │
  └──────────────────────────────────────────────────┘
```

> The `terminate` event transitions from every non-terminal state — `pending`,
> `provisioning`, `starting`, `running`, `stopping`, `stopped`, `rebooting` and
> `error` (`server/app/models/system/node_instance.rb:199-201`), so an instance
> stuck mid-`provisioning` can be terminated directly. This runbook previously
> said it reached only `running`/`stopped`/`error`; that was the pre-fix shape,
> corrected under audit 2026-06-09 finding F4-02 (see the model comment at
> `:194-198`). See [Per-state error recovery](#per-state-error-recovery) for the
> other ways to clear a stuck instance.

## Phase 1 — Create Node ✅

The `Node` is a logical row. No provider resources are touched here.

```javascript
platform.system_create_node({
  name: "edge-tokyo-01",              // REQUIRED — unique within the account
  template_id: "<node-template-id>",  // REQUIRED — composes assigned modules
  description: "Tokyo CDN edge",      // optional
  enabled: true,                      // optional; default true
  worker_id: "<worker-id>",           // optional — Worker that services this node's tasks
  public_address: "203.0.113.10",     // optional
  allocate_public_ip: false,          // optional; default false
  config: {                           // optional JSONB — the only free-form field
    "owner": "edge-team",
    "purpose": "tokyo-cdn-edge"
  }
})
// → { node: { id, name, template_id, worker_id, enabled, template_name,
//             instance_count, module_count, created_at, ... } }
```

> ### ⚠️ Seven arguments this runbook used to document are NOT ACCEPTED
>
> The example above previously passed `account_id`, `hostname`,
> `node_template_id`, `node_platform_id`, `node_architecture_id`,
> `lifecycle_class` and `metadata` — every key it showed. `system_create_node`
> declares only the eight parameters above, and undeclared keys are **dropped
> without an error**, so the old call did not fail in a way that told you what
> was wrong. They are listed here rather than deleted, because an operator who
> planned around one of them needs to see it withdrawn:
>
> | Old key | What is actually true |
> |---|---|
> | `account_id` | Not a parameter on either surface. The node is created in the caller's authenticated account context. |
> | `hostname` | The column is `name` (`system_nodes` has no `hostname`). Unique per account. |
> | `node_template_id` | Renamed to `template_id` on MCP **create** only. REST create takes `node_template_id`, and so does `system_update_node`. |
> | `node_platform_id` | Not on a Node. The platform is chosen on the **NodeTemplate** (`system_node_templates.node_platform_id`, `NOT NULL`) — pick it with `platform.system_create_template`. |
> | `node_architecture_id` | Not on a Node or a template. It follows from the platform (`system_node_platforms.node_architecture_id`, `NOT NULL`). |
> | `lifecycle_class` | **NOT IMPLEMENTED as an argument** — see below. |
> | `metadata` | No such column. `config` (JSONB) is the free-form field, on both surfaces. |

**`lifecycle_class` — you do not set it on a Node; the pool that creates the
Node sets it**

`system_nodes.lifecycle_class` is a real column (`default: "persistent"`,
`NOT NULL`, check constraint `persistent|ephemeral|spot`, mirrored by
`System::Node::LIFECYCLE_CLASSES` and an inclusion validation). Where its value
comes from is not what this runbook used to say:

- **You cannot set it on a node you create.** `system_create_node`'s executor
  slices only `description, enabled, worker_id, public_address,
  allocate_public_ip, config` (`system_fleet_tool.rb`), and REST's `node_params`
  does not permit it (`nodes_controller.rb`). A node created either way takes
  the column default, `persistent`.
- **You cannot change it afterwards.** REST create and update share one
  `node_params` permit list, and `system_update_node` takes the MCP create
  surface with `template_id` renamed to `node_template_id`. None of them
  includes `lifecycle_class`. So the old "treat the class as fixed in practice"
  advice was right about the outcome and wrong about the reason: it is not that
  you *should not* change it, it is that through MCP or REST you *cannot*.
- **You cannot read it back.** Neither `System::NodeSerializer` (REST) nor the
  MCP node serializer emits `lifecycle_class`, so no API response tells you a
  node's class. To see it you need the DB or the Rails console.
- **The one path that produces a non-default value is an InstancePool.**
  `System::InstancePoolService#provision_warming_member!` creates each pool
  member's Node with `lifecycle_class: pool.lifecycle_class` — and a pool's
  class is constrained to `ephemeral|spot`, so **every pool-member node is
  `ephemeral` or `spot`, never `persistent`**. Mostly this happens without you:
  `System::InstancePoolReplenisherJob` is a 60-second Sidekiq cron that POSTs
  replenish for every `active` or `draining` pool, so an active pool with
  `target_size >= 1` mints `ephemeral`/`spot` nodes unattended. The manual
  triggers for the same path are `platform.system_replenish_instance_pool` and
  REST `POST /api/v1/system/instance_pools/:id/replenish`. This is the *only*
  way to influence a Node's class, and it is indirect: you choose it on the pool
  (`platform.system_create_instance_pool`), not on the node — and the reaper
  applies it on its own schedule.
- Every other application writer sets `persistent` or nothing:
  `System::PlatformDeploymentOrchestrator` hardcodes `"persistent"` (the same
  as the default); the `provision_full_stack` skill executor and the
  fulfillment orchestrator omit it entirely. Seed scripts
  (`db/seeds/example_multi_tenant.rb`) write the model directly — not an
  operator path.
- **Nothing reads it.** A tree-wide search of `server/`, `extensions/`,
  `worker/` and the Go agent finds no consumer of a *Node's* `lifecycle_class`;
  the model comment's "short-circuit expensive bootstrap for short-lived
  instances" is aspirational. It records intent today; it changes no behaviour.

One other table carries a same-named column with a **different value set** — do
not transfer conclusions between them. A third column used to share the name and
no longer does (IMP-1e2e7b43b083 renamed it to `lease_class`), because it was a
different axis, not a narrower value set:

| Column | Values | Set by |
|---|---|---|
| `system_nodes.lifecycle_class` | `persistent\|ephemeral\|spot` | not settable directly. `persistent` by default; `ephemeral`/`spot` only on nodes an InstancePool mints (usually via the 60s replenisher cron) |
| `system_instance_pools.lifecycle_class` | `ephemeral\|spot` only — **no `persistent`** | `platform.system_create_instance_pool`, the Instance Pools UI, and GitOps `fleet.yaml` |
| `system_node_instances.lease_class` (**not** a lifecycle class) | nullable, no constraint; carries `task_scoped`, which is invalid on both columns above | the fulfillment orchestrator, for leased task-scoped instances |

So if you want `ephemeral` or `spot` nodes, create an **InstancePool** with that
class and let it provision its members — see
[instance-pool-tuning.md](./instance-pool-tuning.md). The Phase 1 call above
always builds a `persistent` node.

**What else to watch:**
- `template_id` determines which modules will be assigned at bootstrap. To reuse an existing fleet template, query first: `platform.system_list_templates`.
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
- **LocalQemuProvider** — libvirt domain creation with direct kernel boot from M3 artifacts; takes ~10-30 s in `real` mode, instant in `local` mode (the `RecorderRunner`, per `project_local_qemu_provider` memory)

Instance AASM transitions on the happy path: `pending → provisioning → running`
(`mark_provisioning`, then `mark_running` on the first `phase=ready` heartbeat).
If the provider call or boot fails, the worker drives `mark_errored` so the
instance lands in `error` rather than dangling in `provisioning` — there is no
orphaned-`pending` row left behind.

**Idempotent retries.** `system_provision_instance` accepts an `operation_id`.
A retried call carrying the **same** `operation_id` reuses the existing instance
row (tagged in `config->>'operation_id'`) instead of creating a second VM —
this dedups transient-error retries. A retry *without* an `operation_id` falls
back to time-stamped naming and **will** create a distinct instance, so always
thread the same `operation_id` through when retrying a failed provision.

**Verify provisioning:**

```javascript
platform.system_get_instance({ instance_id: "<instance-id>" })
// → { instance: { status: "provisioning", task_id, last_heartbeat_at: null, ... } }

// To watch task progress, list current tasks for the instance and read the matching row:
platform.system_list_tasks({ instance_id: "<instance-id>" })
// (or fetch a single row directly: platform.system_get_task({ id: "<task-id>" }))
```

**What to watch:**
- Provider quota: most providers throttle bulk provisioning. For >10 instances, use `provision_cluster` skill (hard cap 50/call) or sequence calls with `system_create_instance_pool` (slice 7) for warm capacity.
- `MissingNetbootImageError`: the platform-side disk image hasn't been published to OCI yet. Run `system_list_disk_image_publications` to confirm the publication exists with `status=published`.
- LocalQemuProvider: ensure `POWERNODE_LIBVIRT_MODE=real` and `POWERNODE_IMAGE_BASE` points at `extensions/system/initramfs/build`. See [`SMOKE_TEST.md`](../SMOKE_TEST.md).

## Phase 3 — Bootstrap ✅

The provider VM POSTs to `runtime/handshake` once the kernel boots:

1. **Identity discovery** — agent reads from `cmdline` / `virtio-fw-cfg` / cloud metadata; selects the appropriate `IdentityStrategy`
2. **Enrollment** — agent generates Ed25519 keypair, POSTs CSR to `/api/v1/system/node_api/enroll` with bootstrap token; receives signed mTLS cert
3. **Module pull** — agent fetches each assigned module's erofs blob from the PLATFORM's digest-addressed proxy (`/api/v1/system/node_api/files/modules/:id`), not from a registry — the agent has no registry client — and verifies the sha256 digest. Cosign and fs-verity are NOT enforced on this path; see `agent/internal/verify/doc.go`
4. **Mount union root** — erofs lower layer + tmpfs (or `/persist`) overlay; `pivot_root` into composed userspace
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
- `instance_status_sensor` runs every 60 s; fires `system.instance_silent` if no heartbeat in 3 min (`InstanceStatusSensor::SILENT_THRESHOLD = 3.minutes`)
- Module reconciler walks assigned modules; pulls + verifies + mounts updates if module versions changed
- Task lease: agent claims any pending tasks for this instance via `worker_api/tasks` and runs them

**Verify health:**

```javascript
platform.system_get_instance({ instance_id: "<instance-id>" })
// → { instance: {
//      status: "running",
//      last_heartbeat_at: "2026-05-04T13:42:01Z",
//      running_module_digests: { "system-base": "sha256:abc...", ... },
//      ...
//    }}

platform.system_drift_report({ instance_id: "<instance-id>" })
// → { drift: false } or { drift: true, attach: [...], detach: [...], update: [...] }
```

If `drift: true`, the `module_drift_sensor` will emit `system.module_drift`; Fleet Autonomy auto-runs `drift_remediate` (notify_and_proceed policy) on next tick.

## Phase 5 — Drain (records intent only) ⚠️

**`system_drain_instance` does not drain anything.** It writes two marker keys
and emits one `FleetEvent`. Workloads keep running, no service is stopped, and
nothing reads the markers back. Read this section before you use it — the verb
name is the most misleading thing about it.

```javascript
platform.system_drain_instance({
  instance_id: "<instance-id>",
  timeout_seconds: 600            // metadata only — enforces nothing
})
// → { drained: true, instance: {...}, drain_initiated_at, drain_timeout_seconds,
//     next_step: "operator should call system_terminate_instance after workloads relocate" }
```

**What the call does**, in full
(`server/app/services/ai/tools/system_fleet_tool.rb:5216-5254`):

1. Merges two keys into `NodeInstance#config` — `drain_initiated_at` (now,
   ISO8601) and `drain_timeout_seconds` (`:5228-5231`).
2. Creates one `System::FleetEvent` — `kind: "system.instance.drain_initiated"`,
   `severity: "low"`, payload `{ drain_timeout_seconds, initiated_by }` — behind
   an `if defined?(::System::FleetEvent)` guard, so even this is conditional
   (`:5233-5245`).
3. Returns. `drained: true` means *the marker was written* — not that anything
   drained.

**What it does not do.** There is no AASM transition in the handler, so the
instance stays `running`; there is no `draining` instance state and no
`running → stopping → stopped` walk. No container is stopped, no Kubernetes
node is cordoned or drained, no VIP is failed over, no systemd unit on the node
is touched. The tool's own description says so:
"Workloads remain running; operator should call system_terminate_instance after
relocation completes" (`system_fleet_tool.rb:1319`).

**And nothing consumes the markers.** `drain_initiated_at`,
`drain_timeout_seconds` and `drain_initiated_by_user_id` are *written* in
exactly two places — `system_fleet_tool.rb:5228-5231` and
`server/app/services/system/ai/skills/platform_resilience_executor.rb:113-117`
(the `platform_resilience` skill's `drain_instance` branch). **The two writers
are not interchangeable**: the skill writes a third key
(`drain_initiated_by_user_id`) and emits a *different* event — kind
`platform.resilience.drain_started`, severity `info`, wrapped in a bare
`rescue StandardError` that silently swallows a failed emit
(`platform_resilience_executor.rb:119-124`, `:280-291`) — where the MCP verb
emits `system.instance.drain_initiated`, severity `low`, unrescued. Filter on
the wrong kind and you will find nothing; on the skill path there may be nothing
to find — and read in none, across `server/`, `extensions/`,
`worker/`, `frontend/` and the Go agent. The whole `NodeInstance#config` blob
*is* shipped to the node by `GET /api/v1/system/node_api/config`
(`server/app/controllers/api/v1/system/node_api/config_controller.rb:783-793`),
so the markers physically reach the agent — but the only agent caller of that
endpoint, `agent/cmd/powernode-agent/internal/cli/volume_setup_cmd.go:188-215`,
unmarshals into a typed struct reaching just `data.node.disk_policy` and never
looks at the instance config. So the markers, and the event, are an audit trail
for humans — the event is readable back through `system_recent_signals`, which
queries `System::FleetEvent` and takes a `kind` filter
(`system_fleet_tool.rb:1228-1235`, handler `:4738-4752`). Note it is
`system_recent_signals`, not `recent_events`: the latter reads
`Ai::ExecutionEvent` and never sees a FleetEvent
(`server/app/services/ai/introspection/platform_introspection_service.rb:88-106`).
Treat the markers as nothing more than that.

**Parameters — and one that never existed** (`system_fleet_tool.rb:1318-1324`):

| Key | Status | Effect |
|---|---|---|
| `instance_id` | required | The NodeInstance to mark. |
| `timeout_seconds` | optional, default 600 | Stored in `config` and in the event payload. **Enforces nothing**: no timer runs, nothing auto-terminates, nothing reads it back. It is a note to the next human, not a relocation window. |
| `cordon_only` | **does not exist** | Earlier revisions of this runbook showed `cordon_only: false` with the comment "false → also stop services after cordon". There has never been such a parameter, and there is no cordon path to opt out of. `BaseTool#validate_params!` (`server/app/services/ai/tools/base_tool.rb:443-453`) only checks that *required* keys are present — it does not reject extra ones — so the key was accepted, ignored and dropped, and the call returned `success` having done nothing extra. |

**There is no cordon-only capability today.** No MCP verb marks a NodeInstance
unschedulable while leaving it up. Depending on what you actually wanted:

- **Stop the workloads on the node**: `system_stop_instance` really does stop
  the instance (disk and registry row retained, restart with
  `system_start_instance`). That is the blunt version of "also stop services",
  and it is a whole-VM stop, not a per-service one.
- **Keep it from being started or terminated while you work**:
  `system_instance_hold` places an operator ops hold. Every caller reaching
  `System::InstanceControlService` is refused for `start`/`reboot`/`terminate`
  while it is set, and `force` does not override it
  (`server/app/services/system/instance_control_service.rb:32, 95-103`); `stop`
  is deliberately still allowed.
- **Cordon a Kubernetes node**: do it at the Kubernetes layer.
  `kubectl cordon <node>`, then `kubectl drain --ignore-daemonsets`, using the
  cluster's own kubeconfig from `platform.kubernetes_get_kubeconfig`. Nothing in
  `system_drain_instance` reaches kubectl.
- **Stop containers on a Docker host**: use the `docker_*` verbs against the
  DockerHost directly.

**The sequence that actually retires a running instance:**

1. `system_drain_instance` — optional. Take it for the marker and the event if
   you want the audit trail; it buys nothing else.
2. **Relocate the workloads yourself.** This step is manual and unverified:
   drain the Kubernetes node with `kubectl`, stop or migrate containers, move
   the VIP. Nothing on the platform side reports progress, because nothing on
   the platform side knows the relocation started.
3. Confirm by your own means that the node is idle.
4. `system_terminate_instance` — which really does destroy the provider VM:
   it routes through `System::ProvisioningService#terminate_instance`, which
   calls the provider adapter's own `terminate_instance` on the instance's
   `cloud_instance_id` (`server/app/services/system/provisioning_service.rb:265-290`).
   **It is approval-gated** (`action_category: "system.task.terminate"`,
   `system_fleet_tool.rb:426-435`): where policy requires approval the call
   returns `{ pending: true }` with an `approval_request_id` and the instance is
   **not** terminated until an operator approves (`:766-770`). Do not read that
   response as a completed termination — the same mistake this whole section is
   about, one verb along.

> **The failure this ordering exists to prevent.** The response's `next_step`
> tells you to "call system_terminate_instance after workloads relocate", which
> reads as though the drain started the relocation. It did not. Terminating on
> the strength of a drain that only wrote a timestamp destroys the VM with its
> workloads still on it.

**What to watch when you do step 2 by hand** (these are properties of `kubectl
drain` and of your cluster, not of `system_drain_instance`):

- Pod relocation needs capacity on the remaining nodes — a drain stalls if the
  cluster is at capacity. Add capacity first, or accept a partial drain.
- Local-path PVCs do not migrate; pods using them go pending. Plan stateful
  placement accordingly.
- A single-server K3s cluster cannot drain its only server — kubectl loses
  access. Add a second `k3s-server` first, or accept the outage and
  hard-terminate.

## Phase 6 — Decommission ✅

```javascript
platform.system_terminate_instance({ instance_id: "<instance-id>" })
// → { instance_id, status: "terminated" }
// (single-step AASM transition running/stopped/error → terminated; there is
//  no intermediate "terminating" instance state)
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

Stuck states map to the **9 real AASM states**. "bootstrapping" is the agent
boot window inside `provisioning`; drain/terminate are operations (the instance
moves `running → stopping → stopped` or `→ terminated`), not states.

| Stuck in… | Likely cause | Recovery |
|---|---|---|
| `pending` (>5 min) | Worker queue stalled or provider quota | Check `platform.recent_events` for `provider_quota_exceeded`; restart worker via `sudo systemctl restart 'powernode-*-sidekiq.service'`; retry with the **same `operation_id`** |
| `provisioning` (>10 min) | Provider API timeout, libvirt domain creation hung | `platform.system_cancel_task` the provision task; investigate provider. `terminate` does **not** fire from `provisioning` today — see "Clearing a stuck `provisioning` instance" below |
| `provisioning`, agent up but never `running` (>5 min after first heartbeat) | Module pull failure | SSH to node (if SDWAN attached) → `journalctl -u powernode-agent` shows the failed module + reason; common: cosign signature mismatch, OCI 404, network |
| `running` but no heartbeats >3 min | Network partition or agent crash | `platform.recent_events` for `system.instance_silent`; SSH or console-access via libvirt; manual restart of `powernode-agent.service` |
| `error` (terminal) | Provider/boot failure drove `mark_errored` | Inspect `platform.recent_events`; once the cause is understood, `system_terminate_instance` (allowed from `error`) to release provider resources, then re-provision with a fresh `operation_id` |
| Drain stalled (>30 min) | Pods can't reschedule (capacity) | Add capacity, or hard-terminate via `system_terminate_instance` |
| Terminate stalled (>5 min) | Provider VM teardown stuck | Check provider console; in the worst case `system_cancel_task` the teardown task and clean orphan rows manually |

### Clearing a stuck `provisioning` instance

Because the `terminate` event only fires from `running`, `stopped`, or `error`,
an instance wedged in `provisioning` cannot be terminated directly. Recovery
path:

1. `system_cancel_task` the provision task so the worker stops retrying.
2. Reconcile real provider state — for **all** cloud providers (AWS, GCP, Azure,
   OpenStack) and LocalQEMU/Proxmox, the provider's `sync_status` reconciles
   in-flight state against the provider API; a provider that reports the VM as
   gone maps to `terminated`, which stops the controller's in-flight wait loop.
3. If the VM genuinely failed to come up, the worker's `mark_errored` lands the
   instance in `error`; from there `system_terminate_instance` releases any
   provider resources and the row is cleaned up cascade-style.
4. Re-provision with the **same `operation_id`** to reuse the row, or a **fresh**
   one to start clean.

> A proposed remediation (#7) would let `terminate` fire directly from
> `provisioning`/`starting` to simplify this path; it is **not shipped yet**, so
> use the cancel→sync→error→terminate sequence above today.

For all stuck states, use the `attribute_failure` skill (bound to the System Concierge) to enumerate recent module/version changes that may have caused the failure. The skill is invoked through the System Concierge chat agent (operator describes the failure; Concierge calls the executor internally and returns the analysis):

```javascript
// Find the Concierge agent and invoke it with a natural-language ask:
platform.list_agents({ name_contains: "Concierge" })
// → { agents: [{ id: "<concierge-uuid>", name: "System Concierge", ... }] }

platform.execute_agent({
  agent_id: "<concierge-uuid>",   // execute_agent also accepts a slug or exact name
  input: { input: "Attribute the recent failure on instance <instance-id> looking back 24 hours; surface the top candidate module/version change and confidence." }
})
// The Concierge calls the system-attribute-failure executor internally and returns:
// → { candidates: [...], top_candidate: {...}, confidence: "medium", reasoning: "..." }
```

There is no direct `execute_skill` MCP action — skills are executor-shape, invoked by their owning agent. Operators interact with skills by talking to the agent that binds them.

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

LocalQemuProvider modes (the `POWERNODE_LIBVIRT_MODE` value → runner class):
- `real` — `LibvirtRunner`: actual libvirt domain creation + QEMU/KVM boot (default for smoke)
- `local` — `RecorderRunner`: records what the libvirt adapter *would* do (fast; no VM). Default outside production
- `disabled` — `DisabledRunner`: skips provider entirely; useful for unit tests

Switch via `POWERNODE_LIBVIRT_MODE=real|local|disabled` (an unrecognized value raises `Unknown POWERNODE_LIBVIRT_MODE=...`).

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

_Last verified: 2026-06-03_
