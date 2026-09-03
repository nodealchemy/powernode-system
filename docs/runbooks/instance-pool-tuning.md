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
// → { pool: { id, name, status: "active", lifecycle_class, target_size: 5,
//             min_size, max_size, ready_count: 0, warming_count: 0,
//             claimed_count: 0, errored_count: 0, deficit, last_replenished_at } }
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
// → { pool: { id, name, status: "active", lifecycle_class, target_size,
//             min_size, max_size, ready_count, warming_count, claimed_count,
//             errored_count, deficit, last_replenished_at,
//             members: [
//               { id, name, pool_state: "warming", status,
//                 pool_warming_started_at, pool_acquired_at },
//               { id, name, pool_state: "ready", status,
//                 pool_warming_started_at, pool_acquired_at }
//             ] } }
```

`members` is nested **inside** `pool`, not a sibling of it, and a member's own
key is **`id`** (this runbook documented it as `instance_id`, which is not a
key the roster carries) — the same `System::NodeInstance` id you pass to
`system_get_instance({ instance_id: })`. The roster is ordered by
`(pool_state, pool_warming_started_at)` and **capped at 50**: on a pool larger
than that the roster is truncated while the counts beside it are not, so read
occupancy from `ready_count` / `warming_count` / `claimed_count` and treat
`members` as a sample.

## Phase 2 — Claim a pooled instance ✅

```javascript
platform.system_acquire_pooled_instance({
  pool_id: "<pool-id>",           // or pool_name: "ci-runner-pool"
                                  // or lifecycle_class: "ephemeral" (any matching pool)
  acquired_by: "ci-job-12345",    // optional — the claiming actor
  acquired_for: "build-pipeline-1234"  // optional — the workload
})
// → { claim:    { id, acquired_by, acquired_for, acquired_at, event_kind },
//     instance: { id, name, status, pool_state: "claimed", instance_pool_id,
//                 pool_acquired_at, private_ip_address, public_ip_address } }
```

`pool_name`, `pool_id` and `lifecycle_class` select the pool, and all three are
optional. `resolve_pool!` tries them in that order and does not complain about
the combination: `pool_id` wins outright if present, then `pool_name`, and with
**neither** it falls back to *any* active pool that has a ready member (narrowed
by `lifecycle_class` when you pass one). Passing both is not an error and
`pool_name` is simply ignored — so pass one. `acquired_by` and `acquired_for`
are free text and select nothing; they are recorded on the claim (below).

> ### ✅ Acquisition records caller attribution (IMP-68403ec0358d)
>
> **This section used to say the opposite, and the correction is deliberate.**
> Until IMP-68403ec0358d, `acquired_by` and `acquired_for` were *documented but
> undeclared*: `BaseTool#validate_params!` — in the **core** platform tree, not
> this extension: `<powernode>/server/app/services/ai/tools/base_tool.rb:778` —
> checks only that every **required** parameter is present and never rejects an
> *undeclared* key, so a call passing them succeeded, the member really was
> claimed, and the attribution was discarded with nothing in the response to
> say so. Both keys are now declared on the verb and both are recorded.
>
> | Key | Status | What it does |
> |---|---|---|
> | `acquired_by` | **Declared, optional, free text** | The claiming actor (e.g. `"ci-job-12345"`), written to the claim record |
> | `acquired_for` | **Declared, optional, free text** | The workload the member is claimed for (e.g. `"build-pipeline-1234"`), written to the claim record |
> | `claim_id` (response) | **Returned**, as `claim.id` | Correlates the claim to its release. It is a claim id, not a row id in some claims table — see below |
> | `host_address` (response) | **Still not a returned field.** | The addresses are `private_ip_address` and `public_ip_address` |
>
> **What the claim record is.** Two `System::FleetEvent` rows, correlated by the
> claim id, written by `System::InstancePoolService`:
>
> | Kind | Written by | Payload |
> |---|---|---|
> | `system.pool.claimed` | `acquire!`, **inside its transaction** | `claim_id`, `pool_id`, `pool_name`, `node_instance_id`, `instance_name`, `acquired_by`, `acquired_for`, `acquired_at` |
> | `system.pool.released` | `release!`, on **every** disposition | the same, plus `disposition` (`reused` \| `recycled` \| `errored`), `released_at` and `held_seconds` |
>
> The member row still writes exactly `pool_state: "claimed"` and
> `pool_acquired_at`, and `release!` still nulls `pool_acquired_at` on every
> path. **That is precisely why the attribution is not on the row.** A column
> is erased when the member is returned, and "who used this last month" is the
> only question attribution exists to answer. The events outlive the claim.
>
> `system.pool.released` carries the attribution **forward** rather than only
> pointing back at the claim, so summing `held_seconds` by `acquired_by` over a
> month is one query on one kind with no self-join. It fires on the `errored`
> disposition too — the branch where the recycle's terminate failed and the
> member rests at `pool_state: "errored"` with a VM that may still exist and
> still bill. A billing VM with nobody recorded against it is the exact case
> attribution is for.
>
> **Reading it back.** No new verb — `system_recent_signals` already filters
> fleet events by kind and by correlation id:
>
> ```javascript
> platform.system_recent_signals({ kind: "system.pool.released", limit: 200 })
> // → { events: [ { kind, node_instance_id, correlation_id, payload: {
> //       claim_id, pool_id, pool_name, acquired_by, acquired_for,
> //       acquired_at, released_at, held_seconds, disposition } } ], count }
> ```
>
> Pass `correlation_id: "<claim.id>"` instead to get one claim's pair of rows.
> These two kinds are **not** pushed over `SystemFleetChannel`: the live-UI
> broadcast rides on `System::Fleet::EventBroadcaster.emit!`, and the claim
> writes deliberately bypass that seam (see the fail-closed note below).
> They are a queryable record, not a live feed.
>
> **Three honest limits.**
>
> - **The record is retained, not archived.** The nightly
>   `retention_sweep` (`Api::V1::System::WorkerApi::FleetController`) deletes
>   `low`/`medium` fleet events past `POWERNODE_FLEET_EVENT_RETENTION_DAYS`
>   (default **90**) and `high`/`critical` ones past
>   `POWERNODE_FLEET_EVENT_CRITICAL_RETENTION_DAYS` (default 365). Both claim
>   kinds are `low`, so the ledger answers "who used this last month" and
>   roughly the last quarter — it is **not** a permanent cost archive. Export
>   what you need to keep, or raise the retention window fleet-wide.
>
> - **The write is fail-closed, not best-effort.** Both rows go straight to
>   `System::FleetEvent.create!`, *not* through
>   `System::Fleet::EventBroadcaster.emit!`, which rescues `StandardError` and
>   returns `nil` — that seam would have restored the silent-drop this change
>   removes. Because the claim row is written inside `acquire!`'s transaction,
>   a ledger that cannot record the claim rolls the claim back rather than
>   handing out an unattributed member.
> - **Only `release!` closes a claim.** An instance terminated *while claimed*
>   (`system_terminate_instance`) leaves its `system.pool.claimed` row with no
>   matching release, so `held_seconds` is unknown for it. The claim and its
>   acquirer are still recorded; the reaper's `system.pool.claimed_stale` event
>   is the existing surface for a claim nobody returned.
>
> **For CI runner leases, prefer**
> `platform.system_lease_ci_runner({ pool_name, purpose, workflow_run_id, workflow_run_repo })`.
> It wraps this same `acquire!` and additionally writes a
> `System::CiRunnerLease` row carrying the Gitea-specific correlation
> (`runner_name`, `git_owner`, `git_repo`, `workflow_run_id`, `expires_at`) and
> the lease state machine. The claim record above is the general-purpose
> equivalent for every other pool consumer — it is attribution, not a lease:
> append-only, with no lifecycle of its own.

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
//      drain_result: { drained: <ready_terminated>,
//                      terminate_failed: <provider terminate did NOT land>,
//                      claimed_remaining: <still_running> } }
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
  draining pools, though it still recycles) — **this is disputed by the code**;
  see "Do not rely on drain to stop it" under
  [Governance](#governance--which-pool-verbs-are-gated-and-which-are-not)
  before you rely on it
- **`terminate_failed` is not cosmetic.** A member whose provider terminate did
  not land is parked at `pool_state: "errored"` (not `draining`), and a
  high-severity `system.pool.terminate_failed` FleetEvent is emitted carrying
  `failed_instance_ids`. Its VM is very likely still running and still billing.
  The recycle phase retries those terminates on a bounded, backed-off ladder
  (`errored_terminate_max_attempts`); once the cap is spent the member is
  abandoned loudly (`system.pool.terminate_abandoned`, high) and never retried
  again. The retry is skipped — the member is swept straight to `draining` —
  when it has no `cloud_instance_id` or is already `status: "terminated"`,
  i.e. when there is no provider resource left to reclaim. A non-zero
  `terminate_failed` means go look at the provider console; `drained` alone
  does not tell you the pool is gone.
- The pool row stays at `status: "draining"` — there is **no** `drained`
  status. Once members are gone, delete it with `system_delete_instance_pool`

## Phase 5 — Decommission a pool ✅

```javascript
platform.system_delete_instance_pool({ id: "<pool-id>" })
// → { deleted: true, pool_id, pool_name }   // the row is gone; cannot be undone
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

## Governance — which pool verbs are gated, and which are not

Pool verbs are **not** uniformly approval-gated and the split does not follow
cost. Since IMP-067f39468350 the two gates that matter for spend — pool
**create** and the **ceiling raise / archive** PATCH — stand on *both* doors,
the REST route and the MCP verb this runbook tells you to use. The rest still
do not, and **delete is still gated on REST only** while the MCP verb is the
more destructive of the two. Know which is which before you assume an approval
will stop something.

| Verb | Autonomy gate | Declared policy | What actually runs it |
|---|---|---|---|
| Create pool | **Gated on both doors** — `Ai::GatedActions#gate_create!` (REST) and `declare_action` (MCP, IMP-067f39468350) | `system.instance_pool_create` → `require_approval` | `POST /api/v1/system/instance_pools` → `System::Executors::InstancePool::CreatePool`. The MCP verb `system_create_instance_pool` — the one Phase 1 above prescribes — parks under the same category and replays through `Ai::Executors::DeferredToolCall` |
| Delete pool | **Gated on the REST route ONLY** — `gate!` | `system.instance_pool_delete` → `require_approval` | `DELETE /api/v1/system/instance_pools/:id` → `DeletePool`, whose `on_proceed` only sets `status: "archived"`. The MCP verb `system_delete_instance_pool` (Phase 5 above) is **ungated and strictly more destructive** — it calls `pool.destroy!` |
| Update pool — ceiling raise | **Gated on both doors** — `gate_update!` (REST) and `declare_action` (MCP, IMP-067f39468350) | `system.instance_pool_ceiling_raise` → `require_approval` | `PATCH /api/v1/system/instance_pools/:id` with a **higher** `target_size` or `max_size` → `System::Executors::InstancePool::UpdatePool`. `system_update_instance_pool` resolves the same category per payload and replays through `Ai::Executors::DeferredToolCall`. Both doors carry the **replay baseline**: an approval that lands after someone lowered `target_size`/`max_size` inline (decreases are ungated) is REFUSED rather than writing the old high number back — re-submit against current state |
| Update pool — archive | **Gated on both doors** — `gate_update!` (REST) and `declare_action` (MCP) | `system.instance_pool_archive` → `require_approval` | `PATCH {pool: {status: "archived"}}` → `UpdatePool`, or `system_update_instance_pool` with `status: "archived"`. Same state the gated `destroy`'s `on_proceed` writes |
| Update pool — everything else | **Ungated** | `system.instance_pool_update` → `notify_and_proceed` (no gate site reads it) | Size **decreases**, `min_size`, `description`, regions, metadata, `status: "paused"`/`"draining"` → `@pool.update!` inline, on **both** doors |
| Replenish | **Ungated** | `system.instance_pool_replenish` → `auto_approve` | `POST .../:id/replenish` and `system_replenish_instance_pool`, both on `System::InstancePoolService.replenish!` |
| Drain | **Ungated** | `system.instance_pool_drain` → `require_approval` | `POST .../:id/drain` and `system_drain_instance_pool`, both on `InstancePoolService.drain!` — the declared `require_approval` has no gate site to enforce it |
| Recycle stale | **Ungated** | *(no declared category at all)* | `POST .../:id/recycle_stale` and `system_recycle_pool`, both on `InstancePoolService.recycle_stale_members!` — this one **terminates members** |
| Acquire | **Ungated** | `system.instance_pool_acquire` → `auto_approve` | `system_acquire_pooled_instance`, plus four internal callers, on `InstancePoolService.acquire!` |

Two qualifications on the word "ungated", both of which shrink it further:

- **"Ungated" means permission-checked, not unchecked — except for the reaper.**
  `InstancePoolsController#authorize_write!` opens with
  `return if worker_authenticated?`, so the worker-JWT caller described below
  passes with neither a gate nor a permission check. That short-circuit is
  deliberate and load-bearing (the cron has no user), but it means the 60 s
  path clears *both* controls, not just the gate.
- **On MCP, three fleet verbs are gated.** `SystemFleetTool`'s `declare_action`
  calls carrying `action_category`/`executor_class`/`gate_context`/`on_proceed`
  — the quartet `BaseTool#gated_action?` reads — are
  `system_terminate_instance`, `system_create_instance_pool` and
  `system_update_instance_pool` (IMP-067f39468350). Every OTHER pool verb is
  declared `mutating: true` and nothing else, so `gated_action?` is false for
  it: `system_delete_instance_pool`, `system_drain_instance_pool`,
  `system_recycle_pool`, `system_replenish_instance_pool` and
  `system_acquire_pooled_instance` still meet no gate. That remainder is a
  known, tracked gap in the governance registry rollout, not a per-pool
  decision — see the SCOPE note in `system_fleet_tool.rb`.

A third qualification, on where you can *retune* any of this. The Autonomy
modal edits `Ai::InterventionPolicy` rows, and since IMP-5a2b801f3386 the
operator-path (account-wide, agent-less) rows are seeded for the **gated four
only** — `system.instance_pool_create`, `_delete`, `_ceiling_raise`,
`_archive`. The four with no gate site (`_update`, `_replenish`, `_drain`,
`_acquire`) get no operator row, because editing one changed nothing: the
control rendered, saved, and was read by no code path — `_drain` most
misleadingly of all, since it declares `require_approval` and nothing enforces
it. They are still declared, still carried on the **Fleet Autonomy agent's**
policy set (which is what the agent-dispatch path resolves), and an
operator-authored row for one still validates and saves. Gaining a gate site is
what puts a verb back on the operator set.

That change is **forward-only**: `db:seed` runs on first boot only and
`PolicyReconciler` never deletes, so an install seeded before it keeps the four
stale rows and still renders them. No existing sweep collects that row shape —
the deregistered-category pass does not apply, because all eight categories stay
registered via the agent set. So on an established fleet you will still see the
four; deactivating one by hand is harmless and equally inert, and whether the
platform should collect them for you is filed as improvement
`01a063db-c869-7117-b7f6-f88b7061ab4a`.

Note which way round the REST split runs. The two verbs that *are* gated are
pool creation and teardown; **the verb that actually spends money is not** —
replenish is what provisions VMs and mints `ephemeral`/`spot` members, and it
is the one an unattended cron drives. For replenish that is intentional, for
two reasons:

1. **The spend is bounded by a ceiling somebody already set.** A replenish
   tick is idempotent and bounded twice — by `target_size` (the pool's
   `deficit`) and again by the `max_size` headroom cap — so it can never
   exceed the ceiling standing on the pool.

   **Know where that ceiling is locked, and where it is not.** Until
   IMP-24daa05e7a22 it was not locked at all: `PATCH
   /api/v1/system/instance_pools/:id` was ungated and permits `target_size`,
   `max_size` and `status`, so the ceiling could be raised with no approval and
   the next tick would spend up to the new one, and
   `PATCH {pool: {status: "archived"}}` reproduced exactly what the *gated*
   destroy's `on_proceed` does. An **increase** to either size and the
   **archive** transition now gate (table above); decreases, `min_size` and
   `status: "paused"`/`"draining"` stay inline, so `draining` still sidesteps
   the drain policy row.

   The gate is on the **operator doors**, not on the column. IMP-067f39468350
   closed the MCP half — `system_create_instance_pool` and
   `system_update_instance_pool` now park under the same categories as the
   REST twins — but two writers still move
   `target_size`/`max_size`/`status` with no approval, and neither is a defect
   that change closed:

   - `System::Gitops::ApplyService#apply!`, whose `POOL_SCALAR_KEYS` include
     `target_size`, `min_size`, `max_size`, `lifecycle_class` and `status` — a
     GitOps sync raises a ceiling from a repo commit, reached from
     `system_gitops_apply_proposal` and from the decision engine.
   - `System::CiRunnerLeaseService`, which sets `target_size` from configured
     runner demand.

   So read the table as "both operator doors onto the PATCH are gated", not
   "the ceiling is locked".
   `spec/lint/instance_pool_replenish_gating_spec.rb` censuses these writers by
   file and count, so a further one reds rather than quietly widening the
   surface.

   Note what the gate does **not** depend on: `authorize_write!`'s
   `worker_authenticated?` short-circuit skips the **permission** check only.
   It returns into the action body, which still evaluates the gate, so a
   worker-JWT `PATCH` raising `target_size` parks exactly like an operator's.

   Replenish is the actuator, update is the decision — and it is the decision
   the approval now stands in front of, on both the REST route and the MCP
   verb.
2. **It runs unattended.** `System::InstancePoolReplenisherJob` POSTs the
   replenish route every 60 s for every pool it lists, which it fetches with
   `status=active,draining`. A `require_approval` gate there would park one
   approval per pool per minute and stall replenishment fleet-wide — an
   availability decision, not a control.

**To actually stop replenishment**, do not look for an approval to withhold —
there isn't one. Use `target_size = 0`, or `status: "paused"` — `paused` is the
only status `replenish!` refuses (`PoolNotActiveError`).

> **Do not rely on drain to stop it, whatever the rest of this document says.**
> The Phase 4 note above ("a `draining` pool stops being replenished") is one
> of eight places that claim drain halts replenishment; the code disagrees on
> all eight. `InstancePoolReplenisherJob#list_active_pools` fetches
> `status=active,draining` and replenishes every pool it gets back,
> `replenish!` refuses only `paused?`, and `drain!` never zeroes
> `target_size` — so a drained pool still shows a deficit for the next tick to
> fill. Which side is wrong (the code, or eight descriptions of it including
> the approval-card impact strings) is a behavioural decision, filed as offer
> `01a0615e-40ed-70c9-a61e-7732f219b180` rather than settled here. Until it
> is: pause the pool or zero `target_size`; do not assume drain is sufficient.

`System::Executors::InstancePool::ReplenishPool` exists and is the executor
that *would* gate replenish, but nothing constructs a deferred operation
naming it. It is kept as the record of that decision — see the rationale in
`server/app/services/system/executors/instance_pool/replenish_pool.rb`. Both
halves (no producer; no gate site) are pinned by
`server/spec/lint/instance_pool_replenish_gating_spec.rb`, so wiring a gate
reds that guard and forces this table to be updated in the same change.

> **Known gap, filed as offer `01a0615d-e07e-7010-8f07-8f0aace56ea6`.**
> `system.instance_pool_replenish` — along with `_acquire`, `_drain` and
> `_update` — is also seeded onto the *operator* policy path, so it appears in
> the autonomy UI as a control you can edit while no gate site reads it.
> Changing those rows will not change what any of those verbs does. `_update`
> stayed in that list after IMP-24daa05e7a22: the two gated PATCH transitions
> resolve `system.instance_pool_ceiling_raise` and `system.instance_pool_archive`,
> which are the two rows that *are* read.

## Observing pool health

Pool activity emits **nine** `system.pool.*` FleetEvent kinds, so most of it
is queryable via `recent_events` rather than only greppable in the worker log.
Routine replenish/recycle *decisions* (how many members were provisioned or
swept on a tick) are log-only; the events fire on the outcomes worth alerting
on:

| Kind | Severity | Fires when |
|---|---|---|
| `system.pool.member_ready` | low | A warming member's agent posted `phase=ready` and it flipped to `ready` |
| `system.pool.claimed` | low | A member was claimed. This IS the claim record — carries `claim_id`, `acquired_by`, `acquired_for`, `acquired_at` |
| `system.pool.released` | low | The claim was closed. Carries the same attribution plus `disposition` and `held_seconds` |
| `system.pool.claimed_stale` | medium | A claimed member passed `claimed_ttl_seconds` (flag only — never auto-terminated) |
| `system.pool.claimed_stale_heartbeat_flagged` | medium | A claimed member's agent heartbeat went stale (flag only, same rationale) |
| `system.pool.ready_stale_heartbeat_recycled` | medium | A ready member's heartbeat went stale and it was recycled early |
| `system.pool.terminate_failed` | **high** | Drain's provider terminate did not land; member parked `errored` |
| `system.pool.terminate_abandoned` | **high** | The bounded errored-terminate retry ladder spent its cap and gave up |
| `system.pool.mcp_grant_reset_failed` | **high** | A returned member's MCP tool grant could not be reset |

To observe a pool:

- **Live counts** — `system_get_instance_pool` returns `ready_count`,
  `warming_count`, `claimed_count`, `errored_count` (nested under `pool`). A
  `ready_count` that sits at 0 while `target_size > 0` is the user-visible
  failure mode.
- **Pool events** — query `recent_events` for the `system.pool.*` kinds above.
  The two `high` terminate kinds are the ones that cost money: both mean a VM
  may still be running and billing.
- **Worker log** — `journalctl -u 'powernode-*-sidekiq.service' -f | grep
  InstancePool` shows each tick's replenish/recycle/drain *counts*, which the
  events above deliberately do not carry.
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

_Last verified: 2026-09-03_
