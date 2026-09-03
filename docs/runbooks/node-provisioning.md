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
| 4b. Cordon | **Unschedulable, still running** — reversible; new pool acquires, CI runner leases and fleet missions stop landing on it, the replica reconciler counts it as gone (and provisions its replacement) and takes it first on a scale-in, nothing running is touched | <1 s (approval-gated) | `system_cordon_instance` / `system_uncordon_instance` |
| 5. Drain | **Cordon + STOP** — pool member fenced out of the allocator, then the VM is stopped; workload relocation is still manual and must happen FIRST | seconds (the call itself) | `system_drain_instance` |
| 6. Decommission | Provider VM destroyed, FK cascades fire | <1 min | `system_terminate_instance` |

## Lifecycle diagram

The `NodeInstance` AASM has **9 states**: `pending`, `provisioning`, `starting`,
`running`, `stopping`, `stopped`, `rebooting`, `terminated`, `error`. There is
**no `draining` state**, and `system_drain_instance` does not drive the instance
toward one: it walks `running → stopping → stopped`, the same walk
`system_stop_instance` drives (Phase 5 below). `draining` is a `pool_state` on
pooled instances — a different column, and what the drain's CORDON half and a
cordon-only `system_cordon_instance` both write —
not an instance AASM state. There is also
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
         │   system_stop_instance and            │
         │   system_drain_instance both stop it  │
         │   (→ stopped, row + disk retained).   │
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

**`lifecycle_class` — you never set it on a Node, and the column is being
retired**

`system_nodes.lifecycle_class` is a real column (nullable, **no default**, check
constraint `persistent|ephemeral|spot`, mirrored by
`System::Node::LIFECYCLE_CLASSES` and an inclusion validation that now permits
nil). IMP-19843220ac68 settled it as RETIRED: no surface ever accepted it,
nothing ever read it, and as of that change nothing writes it. The column, its
CHECK constraint and its index are dropped one deploy window later. Where its
value used to come from is not what this runbook used to say either:

- **You cannot set it on a node you create.** `system_create_node`'s executor
  slices only `description, enabled, worker_id, public_address,
  allocate_public_ip, config` (`system_fleet_tool.rb`), and REST's `node_params`
  does not permit it (`nodes_controller.rb`). A node created either way now
  carries `NULL`; before the retirement it took the column default,
  `persistent`.
- **You cannot change it afterwards.** REST create and update share one
  `node_params` permit list, and `system_update_node` takes the MCP create
  surface with `template_id` renamed to `node_template_id`. None of them
  includes `lifecycle_class`. So the old "treat the class as fixed in practice"
  advice was right about the outcome and wrong about the reason: it is not that
  you *should not* change it, it is that through MCP or REST you *cannot*.
- **You cannot read it back.** Neither `System::NodeSerializer` (REST) nor the
  MCP node serializer emits `lifecycle_class`, so no API response tells you a
  node's class. To see it you need the DB or the Rails console.
- **The class of a machine lives on the InstancePool, not on the Node.**
  `System::InstancePoolService#provision_warming_member!` used to copy
  `pool.lifecycle_class` onto each member's Node; that copy is gone. A pool's
  class is still constrained to `ephemeral|spot` and is still settable,
  readable and rotatable — a member Node reaches its pool through
  `config["instance_pool_id"]`, which is where anything that ever wants to
  branch on a machine's lifetime must look. Pool members mostly appear without
  you: `System::InstancePoolReplenisherJob` is a 60-second Sidekiq cron that
  POSTs replenish for every `active` or `draining` pool, so an active pool with
  `target_size >= 1` mints members unattended; the manual triggers for the same
  path are `platform.system_replenish_instance_pool` and REST
  `POST /api/v1/system/instance_pools/:id/replenish`. You choose the class on
  the pool (`platform.system_create_instance_pool`), never on the node.
- Both former writers are gone: `System::PlatformDeploymentOrchestrator`
  hardcoded `"persistent"` (the old default, so it moved nothing) and the pool
  service copied the pool's value; the `provision_full_stack` skill executor
  and the fulfillment orchestrator never set it at all. One writer is left, and
  it is not an operator path: the `db/seeds/example_multi_tenant.rb` dev seed
  writes the model directly, and goes when the column is dropped.
- **Nothing reads it, and nothing ever did.** A tree-wide search of `server/`,
  `extensions/`, `worker/` and the Go agent finds no consumer of a *Node's*
  `lifecycle_class`; the model comment's "short-circuit expensive bootstrap for
  short-lived instances" was never built. That, not any single defect, is why
  the column is being retired rather than wired: stopping the writes without
  also removing the `NOT NULL DEFAULT 'persistent'` would have left every pool
  member claiming to be persistent, which is worse than unread.

One other table carries a same-named column with a **different value set** — do
not transfer conclusions between them. A third column used to share the name and
no longer does (IMP-1e2e7b43b083 renamed it to `lease_class`), because it was a
different axis, not a narrower value set:

| Column | Values | Set by |
|---|---|---|
| `system_nodes.lifecycle_class` (**retired**) | `persistent\|ephemeral\|spot`, and now `NULL` | nothing. Never settable through any surface, never read; both writers were removed and the column is nullable with no default pending its drop |
| `system_instance_pools.lifecycle_class` | `ephemeral\|spot` only — **no `persistent`** | `platform.system_create_instance_pool`, the Instance Pools UI, and GitOps `fleet.yaml` |
| `system_node_instances.lease_class` (**not** a lifecycle class) | nullable, no constraint; carries `task_scoped`, which is invalid on both columns above | the fulfillment orchestrator, for leased task-scoped instances |

So if you want `ephemeral` or `spot` machines, create an **InstancePool** with
that class and let it provision its members — see
[instance-pool-tuning.md](./instance-pool-tuning.md). The class is a property of
the pool; the Phase 1 call above builds a node that records no class at all.

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
- Stuck in `bootstrapping`: usually a module pull failure (signature verify, network, OCI 404). Check `journalctl -u powernode-agent` on the node, the provision task's `error_message` (`system_list_tasks({ instance_id })` → `system_get_task`), or the instance's FleetEvents via `system_recent_signals` (exact `kind` or `correlation_id`; the verb has no per-instance filter, so read `node_instance_id` off each event). Not the introspection verb `recent_events` — it reads agent execution events and never returns a FleetEvent.
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

## Phase 5 — Drain (cordon + stop) ⚠️

**`system_drain_instance` stops the instance.** It is no longer the
marker-writing decoy this section used to document: IMP-f4fe1ed1ec1e routed the
MCP verb onto the same actuator as the `platform_resilience` skill's
`drain_instance` action, so there is now ONE drain behaviour reachable through
two doors instead of two doors that disagreed.

```javascript
platform.system_drain_instance({
  instance_id: "<instance-id>"    // the only parameter
})
// → { drained: true, instance_id, instance_name, cordoned, cordon_state,
//     stopped: true, status: "stopped", recommendations: [...] }
```

**What the call does**, in full
(`server/app/services/ai/tools/system_fleet_tool.rb#drain_instance` →
`server/app/services/system/ai/skills/platform_resilience_executor.rb#drain_instance`):

1. Scopes the instance to the caller's account and re-checks
   `system.instances.control` — the grant `system_stop_instance` requires, not
   the coarser one the skill's own MCP entry point maps to.
2. Refuses outright if the instance runs on this control plane's own hosting
   node (INV-1: no self-management).
3. **Cordons** a *ready* pool member: `pool_state = "draining"`, which
   `InstancePoolService#acquire!` reads, so the allocator stops handing it out.
   A **claimed** member is deliberately left alone — it is already
   un-acquirable, and both release paths guard on `pool_state == "claimed"`, so
   flipping it would make it permanently unreturnable. A non-pool instance has
   no allocator to cordon against. A cordon write that RAISES aborts the drain
   *before* the stop: a stopped VM the allocator still calls ready is worse than
   a refused drain.
4. **Stops** the instance through `System::InstanceControlService`, the single
   lifecycle choke point — so an operator ops hold still applies, the AASM
   transition is driven, and the provider adapter (or `shutdown -h now` over SSH
   for a physical node) is dispatched.
5. Emits `platform.resilience.drain_started` (or `platform.resilience.drain_failed`),
   readable back through `system_recent_signals`.

A refused or failed cordon/stop comes back as an ERROR, not as
`drained: true`. Disk and the registry row are retained —
`system_start_instance` brings it back.

**What it still does not do.** Nothing relocates in-flight work first. No
Kubernetes node is cordoned or drained, no container is stopped individually, no
VIP is failed over. The stop is a whole-VM stop; re-check anything that was
mid-flight.

**Parameters** (`system_fleet_tool.rb`, `system_drain_instance` definition):

| Key | Status | Effect |
|---|---|---|
| `instance_id` | required | The NodeInstance to cordon and stop. |
| `timeout_seconds` | **removed** | Accepted until IMP-f4fe1ed1ec1e, stored in `config` and the event payload, and enforcing nothing: no timer ran, nothing auto-terminated, nothing read it back. The skill dropped it with the markers in APO-3b; the MCP verb kept advertising and forwarding it into an executor that ignored it. It is gone from both — the stop path has no knob to map it onto. |
| `cordon_only` | **does not exist** | Earlier revisions of this runbook showed `cordon_only: false` with the comment "false → also stop services after cordon". There has never been such a parameter on this verb. `BaseTool#validate_params!` (`server/app/services/ai/tools/base_tool.rb`) only checks that *required* keys are present — it does not reject extra ones — so the key was accepted, ignored and dropped, and the call returned `success` having done nothing extra. The capability it implied is now its own pair of verbs, `system_cordon_instance` / `system_uncordon_instance` (IMP-0467eee9fc57, below) — deliberately NOT a flag on the drain: a boolean that turns a stop into a not-stop is exactly the kind of parameter that gets dropped silently. |

**The `drain_*` config markers are gone.** `drain_initiated_at`,
`drain_timeout_seconds` and `drain_initiated_by_user_id` were written by the MCP
verb and read by nothing, across `server/`, `extensions/`, `worker/`,
`frontend/` and the Go agent. No writer remains. If you have instances carrying
them from before this change, they are inert history on the `config` blob.

### Cordon-only (unschedulable) mode — `system_cordon_instance` / `system_uncordon_instance`

A **cordon** marks a NodeInstance unschedulable and leaves it up: "stop
scheduling new work here, leave what is running alone" — the Kubernetes
`kubectl cordon` / `kubectl uncordon` shape at the platform layer, and the
reversible half of the drain above. It is the step to take BEFORE relocating
workloads, so the pool does not hand the node a new consumer while you work.

```javascript
platform.system_cordon_instance({
  instance_id: "<instance-id>",
  reason: "kernel patch window"    // required — recorded on the instance and the event
})
// → { instance_id, instance_name, cordoned: true, cordon_state: "fenced",
//     cordon: { cordoned_at, by_user_id, reason, pool_state_before },
//     pool_state: "draining", status: "running", message }

platform.system_uncordon_instance({
  instance_id: "<instance-id>"
})
// → { instance_id, instance_name, cordoned: false, cordon_state: "restored",
//     cordon: null, pool_state: "ready", status: "running", message }
```

**What a cordon does**
(`server/app/services/ai/tools/system_fleet_tool.rb#cordon_instance` →
`server/app/services/system/instance_cordon_service.rb`):

1. Writes the **marker**: `config["cordon"]` = who, why, when, and the
   `pool_state_before` an uncordon restores. `system_get_instance` returns it
   as `cordon` (`null` when not cordoned). A marker alone binds nobody — the
   `drain_*` markers this verb replaces had exactly that defect — which is why
   step 2 exists.
2. **Fences** a *ready* pool member: `pool_state = "draining"`, the one state
   `InstancePoolService#acquire!` never picks and `recycle_stale_members!`
   never touches. Every scheduler that hands a NodeInstance new work goes
   through that one `acquire!` query — `AgentFleetMissionService`, the CI
   runner lease (`CiRunnerLeaseService`), and `system_acquire_pooled_instance`
   — so fencing the `pool_state` fences all of them. The write is conditional
   (`WHERE pool_state = 'ready'`), so a member the allocator claimed a
   millisecond earlier is recorded as `claimed`, not clobbered.
3. Emits `system.instance.cordoned` (severity `low`), readable through
   `system_recent_signals`.

`cordon_state` in the result tells you what actually happened:

| `cordon_state` | Meaning |
|---|---|
| `fenced` | Ready pool member flipped to `draining`. The allocator will not hand it out. **The replenisher counts it as gone** and will provision a replacement up to `target_size`/`max_size`; on uncordon the pool is over target, and nothing trims it back on purpose — `recycle_stale_members!` reaps a ready member once its `pool_warming_started_at` passes `ready_ttl_seconds`, irrespective of `target_size`, so the surplus drains by TTL expiry rather than by a target-aware trim (and the uncordoned member, whose anchor was just reset, is the LAST one it reaches). |
| `claimed` | Pool member a consumer currently holds. Marker only — it is already un-acquirable, and both release paths guard on `pool_state == "claimed"`, so flipping it would strand it. When the consumer returns it, the default `recycled` disposition terminates it; on a pool opted into `reuse_without_reset`, `InstancePoolService#release!` reads the marker and **fences** the member instead of re-admitting it (`pool_state=draining`, release disposition `cordoned`, restore target `ready`) — `system_uncordon_instance` then hands it back as `ready` (IMP-c9adb5a71dca). |
| `already_fenced` | `pool_state` was already `draining` — a drain or recycle is in flight. Marker only; an uncordon will **not** restore it to `ready`. |
| `not_pooled` | Not a pool member. Marker only — there is no allocator to fence. On a **deployment replica** the marker is honoured by `System::Platform::ReplicaReconciler` (IMP-c9adb5a71dca): the cordoned replica is left **out of the live count** (`#live_scope`), so `target_replicas` reconciliation provisions its replacement, and it is the **first scale-in victim** (`#scale_in`: cordoned first, then newest-first among the rest). A cordon alone never triggers a scale-in — the excess is measured on the un-cordoned count — and a pass that spends its budget on cordoned victims converges the rest on the next pass (its message says so). **The Scaling panel reads the same number:** its `actual_replicas` (`deployments_controller#compute_actual_replicas`) is the reconciler's live count — `active.not_cordoned`, one scope pair owned by `System::InstanceCordonService` — and the cordoned rows are disclosed beside it as `cordoned_count`, rendered as a `cordoned` badge (IMP-3d4058389afa). So once a replacement is provisioned the panel reads `target_replicas` live plus the badge for as long as the cordon stands; uncordon or terminate the cordoned replica to clear the badge. On a physical node, a dev cell or ops-hub that no deployment owns, nothing schedules through the platform, so the marker is attribution only; the node_api task lease does not read it (recorded on the task). |

**Refused outright** (an inline error, nothing written, and — because the gate
asks `InstanceCordonService.cordon_refusal` first — no approval parked): a
*warming* member — it is not acquirable yet, and a cordon is not placed ahead
of a member's admission (should a marker reach a warming member by another
route, `NodeInstance#mark_pool_ready!` honours it: the heartbeat promotion
lands on `draining`, never `ready`); an *errored* member (already on its way
out); a terminated instance; an instance that is already cordoned; a blank
`reason`.

**What an uncordon does.** Clears the marker and, for a member THIS cordon
fenced (`pool_state_before: "ready"`) that is still `draining` **and**
`running`, hands it back as `ready` with a fresh ready-TTL anchor (mirroring
the reuse path in `InstancePoolService#release!`, so a member cordoned longer
than `ready_ttl_seconds` is not stale-recycled on the next tick). It **fails
closed** on a fenced member that is not running — a `ready` member that is
stopped would be handed to its next consumer as a dead VM; start it, then
uncordon. It never writes `ready` over a member that left `draining` while
cordoned (recycled, errored): it clears the marker and reports
`cordon_state: "cleared"`. Emits `system.instance.uncordoned`.

**Both directions are approval-gated** under ONE category,
`system.instance_cordon` (`require_approval` by default — declared in
`System::Governance::PolicyDeclarations::INSTANCE_CORDON_OPERATOR_POLICIES`,
seeded by `db/seeds/system_instance_cordon_policies.rb` on first boot and by
`PolicyReconciler` on an already-booted install; tunable in the Autonomy
modal's node-lifecycle section). Where policy requires approval the call
returns `{ pending: true, deferred_operation_id }` and **nothing is written
until an operator approves**. The uncordon is gated on purpose: an agent
re-admitting a node an operator cordoned for maintenance is the ops-hold
lesson — a hold that lifts itself part-way through is worse than no hold. Both
require `system.instances.control`, the grant `system_stop_instance` and the
drain require.

**What a cordon is not.** It is not an ops hold (`system_instance_hold`
refuses `start`/`reboot`/`terminate` at `System::InstanceControlService` —
though deliberately NOT `stop`, see below; a cordon refuses nothing there at
all, it blocks *scheduling* and leaves the whole lifecycle alone — the two
compose). It does not reach kubectl: a
Kubernetes node on the instance still needs `kubectl cordon`. It does not stop
anything — that is the drain.

**Which verb, then.** Depending on what you wanted:

- **Stop new work landing on it, keep it running**: `system_cordon_instance`;
  reverse with `system_uncordon_instance`.
- **Cordon *and* stop a pool member**: `system_drain_instance`, or the
  `platform_resilience` skill's `drain_instance` action — the same code.
  **After deploying IMP-8c0f0fe9a8cf you must re-run `db:seed`**: the
  `Ai::Skill` row's `system_prompt` is what the model actually reads, seeds
  never re-run automatically on an existing install, and the stale text still
  says the branch "cordons nothing and stops nothing" — an actively dangerous
  instruction now that it stops instances.
- **Stop the workloads on the node without touching the pool**:
  `system_stop_instance`. Same choke point, no cordon.
- **Keep it from being started or terminated while you work**:
  `system_instance_hold` places an operator ops hold. Every caller reaching
  `System::InstanceControlService` is refused for `start`/`reboot`/`terminate`
  while it is set, and `force` does not override it
  (`server/app/services/system/instance_control_service.rb:32, 95-103`); `stop`
  is deliberately still allowed — which is why a drain still works against a
  held instance.
- **Cordon a Kubernetes node**: do it at the Kubernetes layer.
  `kubectl cordon <node>`, then `kubectl drain --ignore-daemonsets`, using the
  cluster's own kubeconfig from `platform.kubernetes_get_kubeconfig`. Nothing in
  `system_drain_instance` reaches kubectl.
- **Stop containers on a Docker host**: use the `docker_*` verbs against the
  DockerHost directly.

**The sequence that actually retires a running instance:**

0. `system_cordon_instance` — so the pool stops handing the node new consumers
   while you do step 1. Reversible if you change your mind; the drain below
   finds the member already `draining`, reports `cordon_state: "cordoned"`,
   and leaves the marker on the instance.
1. **Relocate the workloads yourself, first.** This step is manual and
   unverified: drain the Kubernetes node with `kubectl`, stop or migrate
   containers, move the VIP. Nothing on the platform side reports progress,
   because nothing on the platform side knows the relocation started — and the
   drain below will NOT wait for it.
2. `system_drain_instance` — cordons the pool member and stops the VM. Read the
   result: a refusal comes back as an error, and `cordon_state` tells you
   whether the allocator was actually fenced (`cordoned`), whether there was
   nothing to fence (`not_pooled`), or whether the member is `claimed` and must
   be returned with `system_return_pooled_instance`.
3. Confirm by your own means that the node is idle.
4. `system_terminate_instance` — which really does destroy the provider VM:
   it routes through `System::ProvisioningService#terminate_instance`, which
   calls the provider adapter's own `terminate_instance` on the instance's
   `cloud_instance_id` (`server/app/services/system/provisioning_service.rb:265-290`).
   **It is approval-gated** (`action_category: "system.task.terminate"`,
   `system_fleet_tool.rb:426-435`): where policy requires approval the call
   returns `{ pending: true }` with an `approval_request_id` and the instance is
   **not** terminated until an operator approves (`:766-770`). Do not read that
   response as a completed termination.

> **The ordering changed with the behaviour.** While the drain only wrote a
> timestamp, it was safe to call first and relocate afterwards. It now STOPS the
> instance, so relocation has to come first — a drain issued before the workload
> moves takes the workload down with the VM.

**What to watch when you do step 1 by hand** (these are properties of `kubectl
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
| `pending` (>5 min) | Worker queue stalled or provider quota | Read the provision task's `error_message` (`system_list_tasks({ instance_id })` → `system_get_task`) — a provider quota refusal lands there; no `provider_quota_exceeded` FleetEvent kind is emitted. Restart worker via `sudo systemctl restart 'powernode-*-sidekiq.service'`; retry with the **same `operation_id`** |
| `provisioning` (>10 min) | Provider API timeout, libvirt domain creation hung | `platform.system_cancel_task` the provision task; investigate provider. `terminate` does **not** fire from `provisioning` today — see "Clearing a stuck `provisioning` instance" below |
| `provisioning`, agent up but never `running` (>5 min after first heartbeat) | Module pull failure | SSH to node (if SDWAN attached) → `journalctl -u powernode-agent` shows the failed module + reason; common: cosign signature mismatch, OCI 404, network |
| `running` but no heartbeats >3 min | Network partition or agent crash | `platform.system_recent_signals({ kind: "system.instance_silent", limit: 50 })` (or `system_get_silent_instances()` for the live list); SSH or console-access via libvirt; manual restart of `powernode-agent.service` |
| `error` (terminal) | Provider/boot failure drove `mark_errored` | Read the failing task's `error_message` via `system_get_task`, then `system_attribute_failure({ instance_id })` to rank recent module changes; once the cause is understood, `system_terminate_instance` (allowed from `error`) to release provider resources, then re-provision with a fresh `operation_id` |
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

The seed creates: 1 Account → 1 Node (no lifecycle_class — the column is retired) → 1 NodeInstance via LocalQemuProvider, watches the AASM Task progression, and reports the kernel boot pipeline through to multi-user.target. Total runtime: ~15 min on cold boot (TCG without `/dev/kvm`); ~3 min with KVM.

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
