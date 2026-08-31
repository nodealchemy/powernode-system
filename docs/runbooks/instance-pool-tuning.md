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
  pool_id: "<pool-id>"            // or pool_name: "ci-runner-pool"
                                  // or lifecycle_class: "ephemeral" (any matching pool)
})
// → { instance: { id, name, status, pool_state: "claimed", instance_pool_id,
//                 pool_acquired_at, private_ip_address, public_ip_address } }
```

`pool_name`, `pool_id` and `lifecycle_class` are the **only three** parameters
this verb declares, and all three are optional. `resolve_pool!` tries them in
that order and does not complain about the combination: `pool_id` wins outright
if present, then `pool_name`, and with **neither** it falls back to *any* active
pool that has a ready member (narrowed by `lifecycle_class` when you pass one).
Passing both is not an error and `pool_name` is simply ignored — so pass one.

> ### ⚠️ Acquisition records NO caller attribution
>
> **What the claim writes.** `InstancePoolService.acquire!` updates the winning
> member row with exactly two columns:
>
> | Column | Value |
> |---|---|
> | `pool_state` | `"claimed"` |
> | `pool_acquired_at` | the acquisition timestamp |
>
> Nothing else on the row is touched, and there is no separate claim table —
> **the claim IS the `system_node_instances` row.** Its four pool columns are
> `instance_pool_id`, `pool_state`, `pool_acquired_at` and
> `pool_warming_started_at`; `instance_pool_id` and `pool_warming_started_at`
> were both set when the member was provisioned, not by your claim. No
> `FleetEvent` is emitted (unlike `system_drain_instance`, which emits
> `system.instance.drain_initiated` with an `initiated_by`). The only trace of
> who acquired is a `Rails.logger.info` line carrying `pool_id` and `member_id`
> — no caller identity at all.
>
> **Two arguments this runbook used to document are NOT ACCEPTED.** The example
> above previously passed `acquired_by: "ci-job-12345"` and
> `acquired_for: "build-pipeline-1234"` under the comment "Optional metadata
> stamped on the claim record". They are listed rather than deleted, because an
> operator who planned around them for audit or cost attribution needs to see
> them withdrawn:
>
> | Old key | What is actually true |
> |---|---|
> | `acquired_by` | Not declared. Nothing on the claimed row records the caller. |
> | `acquired_for` | Not declared. Nothing on the claimed row records the workload. |
> | `claim_id` (response) | Not returned. There is no claim id, because there is no claim record other than the instance row itself — use `instance.id`. |
> | `host_address` (response) | Not a returned field. The addresses are `private_ip_address` and `public_ip_address`. |
>
> **This does not fail loudly.** `BaseTool#validate_params!` — in the **core**
> platform tree, not this extension:
> `<powernode>/server/app/services/ai/tools/base_tool.rb:443` — checks only
> that every **required** parameter is present; it never rejects an
> *undeclared* key. So a
> call passing `acquired_by` succeeds, the member really is claimed, and the
> attribution is discarded with nothing in the response to say so. The cost is
> paid much later, by whoever opens the pool and finds every claim
> indistinguishable.
>
> **If you need attribution today**, do not claim through this verb. Use
> `platform.system_lease_ci_runner({ pool_name, purpose, workflow_run_id, workflow_run_repo })`
> — it wraps this same `acquire!` and writes a
> `System::CiRunnerLease` row that *does* carry the attribution
> (`purpose`, `git_owner`, `git_repo`, `workflow_run_id`, `leased_at`,
> `expires_at`) alongside `node_instance_id`. It is scoped to Gitea Act runner
> leases; there is no general-purpose equivalent for other pool consumers.

The claim is **atomic**: the platform uses `SELECT ... FOR UPDATE SKIP LOCKED` on the pool member rows to ensure only one caller claims each member (the oldest `ready` member by `pool_warming_started_at`). If no `ready` member exists, the claim raises `NoReadyMembersError`.

After claim:
- The member's `pool_state` flips to `claimed` and `pool_acquired_at` is stamped — the instance **stays in the pool** as a claimed member (its `instance_pool_id` is not cleared)
- `ready_count` drops by 1 (claimed members don't count toward `ready_count + warming_count`)
- Reaper job sees the resulting deficit on its next tick → provisions a replacement warm member

**Use the claimed instance** like any other NodeInstance:

```javascript
platform.system_get_instance({ instance_id: claim.instance.id })
// → standard NodeInstance row with all the modules already running
```

## Phase 3 — Return / terminate a claimed instance ✅

When the workload is done:

```javascript
// Option A: terminate (default for ephemeral)
platform.system_terminate_instance({ instance_id: "<instance-id>" })
// → cascade FKs fire; pool reaper provisions a replacement
```

```javascript
// Option B: hand the member back to its pool
platform.system_return_pooled_instance({
  instance_id: "<instance-id>"
})
// → { returned: true, disposition: "recycled" | "reused" | "errored",
//     instance: { ... }, pool: { ... } }
```

`instance_id` is the **only** parameter this verb declares, and it is required.

> ### ⚠️ `pool_id` is NOT accepted here, and B does not "return to ready" by default
>
> | Old key / claim | What is actually true |
> |---|---|
> | `pool_id` argument | Not declared, and silently dropped (same `validate_params!` behaviour as above). The pool is derived from the member's own `instance_pool_id`; passing a *different* pool's id changes nothing, it does not move the member. |
> | "instance re-enters pool as a member; status flips back to `ready`" | Only on the **opt-in** path. The **default disposition is `recycled`**: the member goes `pool_state: "draining"`, the VM is **terminated**, and the replenisher provisions a *fresh* member. The `"reused"` path — back to `ready`, TTL anchor reset — runs only when the pool carries `metadata["reuse_without_reset"] = true`. |
>
> **Read the `disposition` — the terminate can fail.** When the provider
> terminate does not land, the member rests at `pool_state: "errored"` and the
> call returns `disposition: "errored"`, still `returned: true`. The VM may
> still exist and bill; the member goes onto the bounded errored-terminate
> retry ladder rather than being gone. A caller that ignores `disposition`
> cannot tell that outcome from a clean recycle.
>
> The default is recycle on purpose: re-serving an instance that still carries
> the prior consumer's on-disk state, mounted credentials and agent working
> memory is a cross-tenant leak. Set `reuse_without_reset` only when every
> consumer of the pool is in the same trust domain.

**When to use B:** it is the bookkeeping-correct way to end a claim, and it is
the only route to the `reused` fast path. Under the default disposition it
terminates the instance just as A does — the difference is the pool's books.
`system_terminate_instance` never touches `pool_state`: it detaches the SDWAN
peer, revokes the dev-cell deploy key and fires the `terminate!` transition, so
an A-terminated member's `status` becomes `terminated` while its `pool_state`
stays `claimed` until `prune_dead_records!` reaps the row (retention-day
delay). Until then it still counts in `claimed_count`, which `replenish!`
includes in the `max_size` headroom calculation, and it stays eligible to be
flagged `system.pool.claimed_stale`. Neither is fatal — the replacement was
already provisioned when you *claimed*, not when you returned — but on a pool
run near `max_size` the phantom claimed members are what eventually block
replenishment. Prefer B for pooled members; A is fine for a one-off teardown.

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
| `target_size` increase doesn't replenish | Reaper job not running | Check `sudo systemctl status 'powernode-*-sidekiq.service'`; confirm the `instance_pool_replenisher` cron (`System::InstancePoolReplenisherJob`) is firing every 60 s — or force it with `system_replenish_instance_pool` |
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
- **Worker log** — `journalctl -u 'powernode-*-sidekiq.service' -f | grep
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
