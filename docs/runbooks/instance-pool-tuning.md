# Instance Pool Tuning Runbook

Operator guide for `System::InstancePool` (slice 7 — pre-warmed ephemeral instances with atomic claim and reaper auto-replenishment). Covers pool creation, sizing heuristics, reaping, draining, and troubleshooting.

**Audience:** operators running bursty / ephemeral workloads (CI runners, ML training, batch processing) who need <30 s claim latency instead of 5–10 min cold provisioning.

## When to use a pool

Pools are the right tool when:

- Workloads are **ephemeral** (`lifecycle_class: "ephemeral"` or `"spot"`) — you'll terminate them when done
- You need **fast claim latency** (sub-30s) for burst capacity
- You can afford to **pre-pay** for some idle warm instances in exchange for the latency win

Pools are the **wrong** tool when:

- Workloads are persistent (use direct `system_provision_instance` instead)
- Burst frequency is too low to justify warm instances (cost > savings)
- You need >50 instances simultaneously (use `provision_cluster` skill instead — same warmup latency for everyone, no claim contention)

See [`USE_CASE_MATRIX.md`](../USE_CASE_MATRIX.md) use cases 4 (bursty batch) + 5 (CI runner pool) for context.

## Phase 1 — Create a pool ✅

```javascript
platform.system_create_instance_pool({
  name: "ci-runner-pool",
  description: "Warm pool for Gitea Actions runners",
  template_id: "<ci-runner-template>",         // Template all pool members are built from
  provider_region_id: "region-aws-us-east-1",
  provider_instance_type_id: "type-t3-medium",
  target_size: 5,                               // desired warm members
  min_size: 2,                                  // never reap below this
  max_size: 10,                                 // never replenish above this
  warmup_grace_seconds: 600                     // how long an instance can warm before reaper retries
})
// → { instance_pool: { id, status: "warming", member_count: 0, target_size: 5, ... } }
```

The pool reaper job (`system_pool_replenish`) runs every 60 s, sees `member_count < target_size`, and provisions new instances up to `target_size`. Each new member starts in `status: "warming"` until its agent posts `phase=ready`; then it transitions to `status: "ready"`.

**Verify:**

```javascript
platform.system_get_instance_pool({ id: "<pool-id>" })
// → { instance_pool: { ... }, members: [
//      { instance_id, status: "warming", warming_started_at, ... },
//      { instance_id, status: "ready", warmed_at, ... }
//    ] }
```

## Phase 2 — Claim a pooled instance ✅

```javascript
platform.system_acquire_pooled_instance({
  pool_id: "<pool-id>",
  // Optional metadata stamped on the claim record:
  acquired_by: "ci-job-12345",
  acquired_for: "build-pipeline-1234"
})
// → { instance: { id, status: "running", host_address, ... }, claim_id }
```

The claim is **atomic**: the platform uses `SELECT ... FOR UPDATE SKIP LOCKED` on the pool member rows to ensure only one caller claims each member. If no `ready` member exists, the claim fails with `PoolEmptyError`.

After claim:
- The instance leaves the pool — `pool_id` is nullified
- `member_count` decreases by 1
- Reaper job sees the deficit on next tick → provisions a replacement

**Use the claimed instance** like any other NodeInstance:

```javascript
platform.system_get_instance({ id: claim.instance.id })
// → standard NodeInstance row with all the modules already running
```

## Phase 3 — Return / terminate a claimed instance ✅

When the workload is done:

```javascript
// Option A: terminate (default for ephemeral)
platform.system_terminate_instance({ id: "<instance-id>" })
// → cascade FKs fire; pool reaper provisions a replacement
```

```javascript
// Option B: return to pool (rare — only safe if the instance is truly stateless)
platform.system_return_pooled_instance({
  pool_id: "<pool-id>",
  instance_id: "<instance-id>"
})
// → instance re-enters pool as a member; status flips back to "ready"
```

**When to use B:** the instance has truly no state (e.g., a CI runner that's done a clean checkout teardown). For most workloads, **prefer A** — the cost of provisioning a replacement is fully covered by the pool's warm capacity.

## Sizing heuristics

The right sizes depend on three numbers:

- **C** = claim rate (claims per minute, peak)
- **W** = warmup latency (seconds from `system_create_node` to `phase=ready`)
- **R** = reaper interval (60 s, fixed)

**Minimum target_size** (so the pool never empties under peak load):

```
target_size ≥ ceil(C × (W / 60 + R / 60))
```

Worked example: peak 4 claims/min, warmup 90 s, reaper 60 s →
`target_size ≥ ceil(4 × (1.5 + 1.0))` = **10**.

**min_size** is your "never go below" floor. Set it to the floor of expected baseline load — usually 1 or 2.

**max_size** is your cost ceiling. Set it to the worst-case burst you can afford to pay for (idle warm capacity costs the same as active capacity).

**Tuning knobs:**

- If pool is consistently empty when needed: increase `target_size` or pre-bake a NodePlatform image to reduce W.
- If pool is consistently >90% idle: decrease `target_size`.
- If reaper isn't keeping up after spikes: increase `target_size` (the reaper provisions delta on each tick; smaller delta = faster recovery).

## Phase 4 — Drain a pool ⚠️

To wind down a pool (e.g., load is gone, or you're switching templates):

```javascript
platform.system_drain_instance_pool({
  id: "<pool-id>",
  terminate_members: true                  // false → release members (claim them all)
})
// → { drained: true, terminated_count: 5 }
```

`terminate_members: true` (default) destroys all pool members. `false` releases them as standalone NodeInstances (they survive but no longer back the pool).

**What to watch:**

- Drain is async — the pool's `status: "draining"` until all members are processed
- `target_size` is set to 0 during drain; reaper stops replenishing
- After drain, the pool row remains with `status: "drained"`. To delete: `system_delete_instance_pool`

## Phase 5 — Decommission a pool ✅

```javascript
platform.system_delete_instance_pool({ id: "<pool-id>" })
// → permanently removes the pool row; cannot be undone
```

Only valid after a successful drain. Trying to delete a non-empty pool returns `PoolNotEmpty`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pool stuck at 0 members despite `target_size: 5` | Provider quota exhausted, or template references a missing module version | Check `recent_events` for `provider_quota_exceeded` or `module_pull_failed`; resolve and the reaper retries |
| Members stuck `warming` >10 min | Bootstrap failed (module pull, mTLS handshake) | Use `attribute_failure` skill; common causes: missing `Sdwan::Peer`, expired bootstrap token |
| `PoolEmptyError` despite `member_count: 5` in dashboard | All 5 members are still `warming` (none `ready` yet) | Either wait, increase `target_size`, or pre-bake a faster boot image |
| Pool stuck `draining` | Provider VM teardown stalled | Check provider console; manually cancel via `system_cancel_task` |
| `target_size` increase doesn't replenish | Reaper job not running | Check `sudo systemctl status powernode-worker@default`; confirm `system_pool_replenish` job in Sidekiq queue |
| Members continuously cycle (warm → claim → terminate → repeat) | Claim rate exceeds replenish rate | Increase `target_size`; reduce W (pre-bake image) |
| Pool's claim metric oscillates | Sizing too tight; reaper can't keep up after bursts | Add more headroom: `target_size += 2 × max_burst_size` |

## Pool sensor signals

The pool reaper emits `FleetEvent` signals visible in `recent_events`:

- `pool.member_provisioned` — replenish created a new member
- `pool.member_warmed` — member transitioned `warming → ready`
- `pool.member_warmup_timeout` — member exceeded `warmup_grace_seconds`; reaper terminates + provisions another
- `pool.empty_during_claim` — `system_acquire_pooled_instance` failed because no ready member existed
- `pool.drain_started` / `pool.drain_completed`

Tune your dashboards to alert on `pool.empty_during_claim` — that's the user-visible failure mode.

## How the System Concierge should use this

When an operator chats "I need 50 ephemeral instances for an ML run" / "claim a CI runner" / "tune the warm pool":

1. For one-off ephemeral bursts, surface the choice: pool (existing) vs `provision_cluster` (one-shot)
2. For pool tuning, ask for current `C × W` numbers and propose a `target_size`
3. For claims, surface `system_acquire_pooled_instance` directly
4. For drains, use `request_confirmation` since this is destructive

## Related docs

- [`USE_CASE_MATRIX.md`](../USE_CASE_MATRIX.md) — use cases 4 (bursty batch) + 5 (CI runner pool)
- [`runbooks/node-provisioning.md`](./node-provisioning.md) — for non-pool ephemeral provisioning
- [`SKILL_EXECUTORS.md`](../SKILL_EXECUTORS.md) — `provision_cluster` for one-shot multi-instance bursts
- [`FLEET_SENSORS.md`](../FLEET_SENSORS.md) — `instance_status_sensor` covers pool members
