# Instance Pool Tuning Runbook

> Status: active

Operator guide for `System::InstancePool` (pre-warmed ephemeral instances with atomic claim and reaper auto-replenishment). Covers pool creation, sizing heuristics, reaping, draining, and troubleshooting.

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
  template_id: "<ci-runner-template>",         // Template all pool members are built from (required)
  target_size: 5,                               // desired warm+ready members (required)
  min_size: 2,                                  // lower bound (default 0)
  max_size: 10,                                 // upper bound (default target_size + 10)
  lifecycle_class: "ephemeral",                 // "ephemeral" | "spot" (default "ephemeral")
  provider_region_id: "region-aws-us-east-1",
  provider_instance_type_id: "type-t3-medium"
})
// → { instance_pool: { id, status: "active", target_size: 5,
//      ready_count: 0, warming_count: 0, claimed_count: 0, ... } }
```

> The warming-retry window isn't a top-level create field. The reaper reads
> it from `metadata["warming_timeout_seconds"]` (with `metadata["ready_ttl_seconds"]`
> for stale ready members) — set those on the pool's `metadata` if you need
> to override the defaults.

A new pool's **`status`** is `active` (the pool-level lifecycle:
`active | paused | draining | archived`). "warming" / "ready" / "claimed"
are per-member **`pool_state`** values — don't confuse the two.

The reaper — worker job `System::InstancePoolReplenisherJob`, scheduled as
the `instance_pool_replenisher` cron in `worker/config/sidekiq.yml` (every
60 s) — runs a 2-phase tick (recycle stale members, then replenish). When
`ready_count + warming_count < target_size` it provisions new members up to
`target_size`. Each new member starts in `pool_state: "warming"` until its
agent posts `phase=ready`; then it flips to `pool_state: "ready"`.

**Verify:**

```javascript
platform.system_get_instance_pool({ id: "<pool-id>" })
// → { instance_pool: { ..., status: "active", ready_count, warming_count, claimed_count },
//      members: [
//      { instance_id, pool_state: "warming", ... },
//      { instance_id, pool_state: "ready", ... }
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

The claim is **atomic**: the platform uses `SELECT ... FOR UPDATE SKIP LOCKED` on the pool member rows to ensure only one caller claims each member (the oldest `ready` member by `pool_warming_started_at`). If no `ready` member exists, the claim raises `NoReadyMembersError`.

After claim:
- The member's `pool_state` flips to `claimed` and `pool_acquired_at` is stamped — the instance **stays in the pool** as a claimed member (its `instance_pool_id` is not cleared)
- `ready_count` drops by 1 (claimed members don't count toward `ready_count + warming_count`)
- Reaper job sees the resulting deficit on its next tick → provisions a replacement warm member

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
- **W** = warmup latency (seconds from a member's provision to `phase=ready`)
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
platform.system_drain_instance_pool({ id: "<pool-id>" })
// → { pool: { ..., status: "draining" },
//      drain_result: { drained: <ready_terminated>, claimed_remaining: <still_running> } }
```

Drain sets the pool `status` to `draining`, terminates every **ready**
member at the cloud provider, and halts replenishment. **Claimed** members
keep running — they finish their workload and are torn down by the normal
terminate flow. There is no `terminate_members` flag and no "release them
as standalone" mode; drain always terminates the ready members.

**What to watch:**

- Drain runs in a single transaction (synchronous) — by the time the call
  returns, ready members have had `terminate_instance` issued
- A `draining` pool stops being replenished (the reaper skips replenish for
  draining pools, though it still recycles)
- The pool row stays at `status: "draining"` — there is **no** `drained`
  status. Once members are gone, delete it with `system_delete_instance_pool`

## Phase 5 — Decommission a pool ✅

```javascript
platform.system_delete_instance_pool({ id: "<pool-id>" })
// → permanently removes the pool row; cannot be undone
```

Only valid once the pool has **zero** members. Trying to delete a pool that
still has members returns an error: `pool <name> still has N member(s) —
drain first via system_drain_instance_pool`. Drain the ready members, wait
for any claimed members to finish their normal terminate, then delete.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pool stuck at 0 members despite `target_size: 5` | Provider quota exhausted, or template references a missing module version | Check `recent_events` for `provider_quota_exceeded` or `module_pull_failed`; resolve and the reaper retries |
| Members stuck `warming` >10 min | Bootstrap failed (module pull, mTLS handshake) | Use `attribute_failure` skill; common causes: missing `Sdwan::Peer`, expired bootstrap token |
| `NoReadyMembersError` despite 5 members in dashboard | All 5 members are still `warming` (`ready_count: 0`) | Either wait, increase `target_size`, or pre-bake a faster boot image |
| Pool stuck `draining` | Provider VM teardown stalled, or claimed members still running | Check provider console; for a stalled teardown task cancel via `system_cancel_task` |
| `target_size` increase doesn't replenish | Reaper job not running | Check `sudo systemctl status powernode-worker@default`; confirm the `instance_pool_replenisher` cron (`System::InstancePoolReplenisherJob`) is firing every 60 s — or force it with `system_replenish_instance_pool` |
| Members continuously cycle (warm → claim → terminate → repeat) | Claim rate exceeds replenish rate | Increase `target_size`; reduce W (pre-bake image) |
| Pool's claim metric oscillates | Sizing too tight; reaper can't keep up after bursts | Add more headroom: `target_size += 2 × max_burst_size` |

## Observing pool health

The reaper does **not** emit dedicated `pool.*` FleetEvent signals — its
replenish / recycle / drain decisions go to the worker log
(`[InstancePoolService] ...`, `[InstancePoolReplenisherJob] ...`). To
observe a pool:

- **Live counts** — `system_get_instance_pool` returns `ready_count`,
  `warming_count`, `claimed_count`, `errored_count`. A `ready_count` that
  sits at 0 while `target_size > 0` is the user-visible failure mode.
- **Worker log** — `journalctl -u powernode-worker@default -f | grep
  InstancePool` shows each tick's replenish/recycle/drain activity.
- **Underlying instance events** — individual member provision / terminate
  flows surface in `recent_events` like any other NodeInstance lifecycle
  (e.g. `provider_quota_exceeded`, `module_pull_failed`).

Alert on a sustained `ready_count == 0` (with `target_size > 0`) — that
means claims will start raising `NoReadyMembersError`.

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

_Last verified: 2026-06-03_
