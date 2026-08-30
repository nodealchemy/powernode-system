# Tutorial 06 — Rolling module upgrade with canary

> Status: active

> ## ⚠️ The batched runtime this tutorial described is NOT IMPLEMENTED
>
> `RollingModuleUpgradeExecutor` computes a **plan and stops**. There is no
> batch advancer, no health check and no circuit breaker anywhere in the
> platform for module upgrades — approving a plan rolls nothing out. Earlier
> revisions of this page described all three as working. They never were.
>
> `batch_pct` is **not** a safety control. It sizes groups in a document.
>
> The plan-mode walkthrough (Steps 1–2) is still accurate and useful for
> sizing an upgrade. Everything that claimed to *execute* a plan is marked
> NOT IMPLEMENTED below. For the procedure that actually moves a fleet
> today, jump to [What to do instead](#what-to-do-instead).

> **What you'll learn:** How to compute a batched upgrade plan, what the
> platform does and does not do with it, and the manual procedure that
> actually moves a module version across a fleet — including why that
> procedure cannot be batched either.
>
> **Time:** ~10 min
>
> **Builds on:** [Tutorial 02](./02-first-module.md) (you understand module
> versions + promotion) and [Tutorial 03](./03-docker-runtime.md) (you have a
> running fleet of instances with modules assigned).
>
> **Sets you up for:** [Tutorial 07 — CVE response](./07-cve-response.md) —
> CVE remediation orchestrates the same `rolling_module_upgrade` skill
> across affected modules.

## What you're building

```mermaid
flowchart TD
    Op[Operator] --> Plan[RollingModuleUpgradeExecutor<br/>batch_pct=20%]
    Plan --> Plan2[Plan computed:<br/>50 instances → 5 × 10]
    Plan2 --> Stop([Returns the plan.<br/>Nothing advances the batches.])

    Stop -.->|NOT IMPLEMENTED| Ghost1[Batch 1 upgraded]
    Ghost1 -.->|NOT IMPLEMENTED| Ghost2[Health check]
    Ghost2 -.->|NOT IMPLEMENTED| Ghost3[Circuit breaker]

    Op --> Manual[Manual procedure:<br/>see 'What to do instead']
    Manual --> Ptr[Repoint NodeModule<br/>current_version_id]
    Ptr --> Fleet[Every instance carrying<br/>that module converges]

    style Ghost1 stroke-dasharray: 5 5
    style Ghost2 stroke-dasharray: 5 5
    style Ghost3 stroke-dasharray: 5 5
```

The dashed path is what earlier revisions of this tutorial described. It does
not exist. The solid paths are what the platform does today.

## Concept refresher

**`rolling_module_upgrade`** is a skill executor (see
[`SKILL_EXECUTORS.md`](../SKILL_EXECUTORS.md)). What it does, in full:

1. Validates `batch_pct` is 1–100
2. Looks up the module and confirms `target_version_id` appears in its
   version list
3. Lists the template's `running`/`starting` instances and slices them into
   batch-sized groups
4. Returns the plan, with `executed: false`

Then it returns. That is the whole executor
([`rolling_module_upgrade_executor.rb`](../../server/app/services/system/ai/skills/rolling_module_upgrade_executor.rb)).

**NOT IMPLEMENTED — no code in the platform does any of the following:**

| Promised | Reality |
|---|---|
| Walks batches one at a time after approval | Nothing advances the batches. There is no reconciler that reads the plan; the plan is returned to the caller and discarded |
| Per-batch health checks against `running_module_digests` | The executor never reads `running_module_digests`. No health check exists |
| Circuit breaker trips at `max_consecutive_failures` | No breaker exists. The argument is echoed into the returned `circuit_breaker` hash (now `status: "not_implemented"`) and read by nothing |
| `health_timeout_sec` bounds a health window | Echoed into the same hash. Read by nothing |
| Emits `module.upgrade.*` events | Nothing in the platform emits these events |
| Continuation ApprovalRequest with `continue_anyway` / `rollback_completed_batches` / `abort` | No such ApprovalRequest type, and no handler for any of the three options |

**Why isn't `batch_pct` a safety control?** Two independent reasons, and the
second survives even if someone builds the advancer:

1. Nothing executes the batches, so the grouping has no runtime effect at all.
2. The version an instance receives is resolved from
   `NodeModule#current_version_id` — a **per-module** pointer, read at download
   time by the node-facing endpoint. There is no per-instance version
   selection, so there is nothing to batch *over*. Moving that pointer moves it
   for **every instance carrying that module** simultaneously.

**What about the approval?** `system.fleet_rolling_upgrade` really is
`require_approval` ([`FLEET_SENSORS.md`](../FLEET_SENSORS.md)), and the plan
really does carry `requires_approval: true`. The approval gate is real. What
is missing is anything that acts on the approval.

**Where this shape *is* implemented:** `boot_image_drift_rollout` does the
equivalent for **boot images** — it dispatches each batch through
`UpgradeDispatcher` and converges tick-by-tick by re-planning off its own
drift sensor, canary-first and halting on the first failed batch. It needs no
batch advancer because convergence is tick-driven. No equivalent lane exists
for modules.

## Prerequisites

| Requirement | How |
|---|---|
| Existing fleet ≥10 NodeInstances assigned a common module (e.g., `nginx 1.24.0`) | Provision via Tutorial 01 + assign via Tutorial 02 pattern |
| New version (`nginx 1.26.0`) published, plus the version id you will target | Tutorial 02 step 6–8. `promotion_state` is not checked by `RollingModuleUpgradeExecutor` — it accepts any version id present in the module's version list, so a `built` version is a valid target. It does not check `oci_digest` either — it only copies that into the plan as `target_oci_digest` — so verify the target carries one yourself before moving the pointer |
| Operator permission `system.fleet_rolling_upgrade` (often paired with approval rights) | Default for admin users |

## Step 1 — Identify the upgrade target

```javascript
platform.system_list_module_versions({ module_id: "<nginx-module-id>" })
// → { versions: [
//      { id: "v-1.24.0", promotion_state: "live", ... },
//      { id: "v-1.26.0", promotion_state: "blessed", ... }
//    ] }

platform.system_list_instances({ template_id: "<edge-template>" })
// → { instances: [{ id, status: "running", running_module_digests: { nginx: "sha256:..." } }, ...50] }
```

**Expected outcome:** confirm 50 instances running v1.24.0, and v1.26.0
present in this list — being in the list is what makes it a valid target,
not its `promotion_state`. Check it carries an `oci_digest`.

## Step 2 — Plan the upgrade (dry-run via the executor)

The `rolling_module_upgrade` skill is a `monitor`-agent executor: in
production the **autonomy reconciler** runs the batches (Step 3), but you
can compute the plan up-front in **plan mode** by invoking the executor
directly. (There is no `execute_skill` MCP action — the executor is a Ruby
class; run it via `rails runner` or a seed, exactly as
[`db/seeds/example_rolling_upgrade.rb`](../../server/db/seeds/example_rolling_upgrade.rb)
does.)

```ruby
result = ::System::Ai::Skills::RollingModuleUpgradeExecutor.new(
  account: account, agent: fleet_autonomy_agent
).execute(
  template_id:               "<edge-template>",
  module_id:                 "<nginx-module-id>",
  target_version_id:         "v-1.26.0",
  batch_pct:                 20,
  max_consecutive_failures:  2,
  health_timeout_sec:        300
)
# → {
#      total_instances: 50,
#      batch_size: 10,
#      batch_count: 5,
#      estimated_total_seconds: 1500,
#      circuit_breaker: { trips_after_consecutive_failures: 2,
#                         health_timeout_sec: 300,
#                         status: "not_implemented" },
#      batches: [
#        { index: 0, instance_ids: [...10], size: 10,
#          estimated_seconds: 1200, status: "planned" },
#        ...
#      ],
#      executed: false,
#      note: "PLAN ONLY — nothing advances these batches. ..."
#    }
```

(Defaults if you omit them: `batch_pct: 10`, `max_consecutive_failures: 2`,
`health_timeout_sec: 600`.)

**Expected outcome:** a plan showing 5 batches of 10 instances each.

Read the returned fields carefully:

- `status: "not_implemented"` — the `circuit_breaker` hash is your two
  arguments echoed back. It is not evidence of a live gate.
- `executed: false` — the plan was computed and nothing was done with it.
- `estimated_total_seconds: 1500` is an ETA hint only (a flat
  `ETA_PER_INSTANCE_SEC = 120` × instance count). It is not a measured
  health window, and no batch is timed against it.

**The plan is still useful** — it tells you how many instances carry the
module and confirms the target version resolves. Treat it as a sizing
document, then perform the upgrade with the manual procedure in
[What to do instead](#what-to-do-instead).

## Step 3 — Approve the plan — NOT IMPLEMENTED

An `ApprovalRequest` is genuinely created and genuinely gates
(`system.fleet_rolling_upgrade` is `require_approval`), and you can approve it
in `/app/approvals`. **Approving it has no effect on the fleet.** No reconciler
reads the plan; nothing starts executing on the next tick or any tick.

There is also no "Edit plan" affordance that changes a rollout, because there
is no rollout — editing `batch_pct` or `max_consecutive_failures` only changes
numbers in a document.

## Step 4 — Watch progress — NOT IMPLEMENTED

```javascript
// NOT IMPLEMENTED — nothing in the platform emits module.upgrade.* events.
// `recent_events` does not declare a `kind_prefix` parameter either, so this
// call is doubly wrong: it would not filter even if the events existed.
platform.recent_events({ kind_prefix: "module.upgrade", limit: 100 })
// → no module.upgrade.* events, ever
```

There is no "Active rolling upgrades" panel at `/app/system/operations`.

To observe a module upgrade you performed manually, poll the instances
directly — see [Verification](#verification) below.

## Step 5 — Circuit breaker scenario (drill) — NOT IMPLEMENTED

**Do not attempt this drill.** It reads as a safe rehearsal and is the
opposite: it instructs you to publish a deliberately broken version, on the
promise that a circuit breaker stops the rollout after two failures. No
circuit breaker exists. If you separately repoint the module at the broken
version (the manual procedure below), **every instance carrying that module
converges on it** with nothing to stop the spread.

None of the following exists:

- the `module.upgrade.circuit_breaker_tripped` event
- the `rolling_upgrade_continuation` ApprovalRequest type
- the `continue_anyway` option — no handler
- the `rollback_completed_batches` option — no handler, and no record of which
  batches "completed" to roll back
- the `abort` option — no handler

Your only real stop button is repointing `current_version_id` back to the
previous version yourself, which is the same one-call operation as rolling
forward. Confirm it is available **before** you move the pointer — see the
next section.

## What to do instead

There is **no automated bound** on a module upgrade today: no batching, no
health gate, no automatic stop. The procedure below is what actually moves a
fleet, and it is deliberately written to make its own limits visible rather
than to look like a supervised rollout.

**The pointer, not the promotion state, is what the fleet serves.** A node
downloading a module resolves `NodeModule#current_version_id`
(`NodeApi::ModulesController#download` reads `@module.current_version&.artifact`).
Promoting a version through `staging → blessed → live` advances a label and
changes nothing about what the fleet receives — see
[Tutorial 02](./02-first-module.md) and
[`module-authoring.md`](../runbooks/module-authoring.md).

### 1. Verify the target before you move anything

```javascript
platform.system_list_module_versions({ module_id: "<nginx-module-id>" })
```

The target version must carry an `oci_digest` — without one it has no
mountable artifact and instances will fail to mount the module.

### 2. Confirm you have a way back — BEFORE the flip

This is the step that replaces the circuit breaker, and it is the only
pre-flight check that materially bounds your risk.

A rollback target must be a version of the same module that is
`rollback_usable?`: it has an `oci_digest`, and its recorded artifact size is
above the non-empty floor (`system.module_publish.min_artifact_bytes`) — a
version with an *unknown* size is accepted, since old rows predate size
recording. If the version you are leaving is the only usable one, moving the
pointer forward is a one-way door until you republish a good build.

### 3. Move the pointer

```javascript
platform.system_rollback_module_version({
  module_id:  "<nginx-module-id>",
  version_id: "<target-version-uuid>",   // a NodeModuleVersion UUID
  reason:     "nginx 1.24.0 → 1.26.0"
})
```

Despite the name, this is the **sanctioned writer of `current_version_id`**
(it calls `NodeModule#promote_to_version!`) and it imposes no direction — it
moves the pointer forward as readily as backward, subject only to the
`rollback_usable?` check above. `system_promote_module_version` will **not**
do this; it advances `promotion_state` only.

Note that `promote_to_version!` also arms `RestartAfterUpdate`, so services
provided by that module restart as instances converge.

### 4. Understand what you just did

The pointer is per-module. **Every instance carrying that module** now
converges on the new version at its own next reconcile — not just the ones you
are watching, and not in any order you control. There is no batch.

`system_refresh_instance_modules` pulls a *single* instance forward
immediately by queueing a `sync_modules` task:

```javascript
platform.system_refresh_instance_modules({ instance_id: "<instance-id>" })
```

Use it to inspect one instance on the new version sooner than the others.
**It does not hold the other instances back** — it changes *when* an instance
converges, never *what* it converges to. Calling it in groups looks like a
batched rollout and is not one; the rest of the fleet is already moving.

### 5. Watch, and be ready to reverse

```javascript
platform.system_get_instance({ instance_id: "<sample-instance>" })
// → { instance: { running_module_digests: { "<nginx-node-module-id>": "sha256:..." } } }
```

If the new version is bad, reverse it with the same verb from step 3, naming
the previous version. That is a manual decision by a watching operator — there
is nothing automatic behind you.

### If you need a real blast-radius bound

Since a module's pointer cannot be scoped to part of a fleet, genuine
staging requires separating the *scope*, not the rollout:

- **[Instance pools](./08-instance-pool.md)** — for stateless workloads,
  replace instances rather than upgrading in place: claim a fresh instance on
  the new version, drain the old one. Blast radius is one instance at a time
  and rollback is "stop claiming".
- **A separate module row for the canary template** — two `NodeModule` rows
  have two independent `current_version_id` pointers, so you can move one
  without moving the other. This is a real cost (two modules to publish and
  keep in step) and is the honest price of staging today.

## Verification

Once the fleet has converged (each instance at its own next reconcile —
there are no batches to complete):

```javascript
platform.system_get_instance({ instance_id: "<sample-instance>" })
// → { instance: { running_module_digests: { "<nginx-node-module-id>": "sha256:<v1.26-digest>", ... } } }
//    (keyed by node_module_id, not by module name)
```

Compare that digest against the target version's `oci_digest`. This is a
per-instance check and you will need to repeat it across the instances you
care about — poll until they converge, or until one does not.

`system_drift_report` answers the same question for **one instance**
(`{ instance_id }`); it has no template-wide form. There is no working
fleet-wide drift answer: `system_platform_maintenance({ op: "drift_check" })`
is template-scoped but its detector is a hardcoded stub.

## Extract a learning

If you ran a real upgrade, record what you learned about **the manual
procedure** — not about batch sizing, which had no effect:

```javascript
platform.create_learning({
  title: "nginx 1.24 → 1.26 module upgrade — pointer flip converged the edge fleet in ~N min",
  category: "best_practice",
  content: "Repointed current_version_id via system_rollback_module_version. All 50 instances converged within N minutes with no batching (the pointer is per-module, so the fleet moves together). Confirmed a usable rollback target existed first. Watch: RestartAfterUpdate armed, so nginx restarted as each instance converged.",
  tags: ["module-upgrade", "nginx", "current-version-pointer"]
})
```

## Cleanup

**Do not re-run the executor to roll back — it does nothing.** Reverse a bad
upgrade the same way you applied it, by moving the pointer:

```javascript
platform.system_rollback_module_version({
  module_id:  "<nginx-module-id>",
  version_id: "<previous-version-uuid>",   // a NodeModuleVersion UUID, not "v-<semver>"
  reason:     "reverting 1.26.0"
})
```

Omitting `version_id` picks the newest other version that is
`rollback_usable?`, which is usually what you want for an emergency revert.

## Troubleshooting

**Approval never appears** — check that `system.fleet_rolling_upgrade` is
in the agent's intervention policies and not blocked. Inspect:

```javascript
// agent_introspect resolves agent_id by UUID only — a slug like
// "fleet_autonomy_agent" silently resolves to nothing. Look up the UUID first:
platform.list_agents()
// → { agents: [{ id: "<fleet-autonomy-uuid>", name: "Fleet Autonomy", ... }, ...] }

platform.agent_introspect({ agent_id: "<fleet-autonomy-uuid>" })
// Look for "intervention_policies" containing system.fleet_rolling_upgrade
```

**Batch never starts after approval** — **this is expected and is not a
fault.** Nothing advances the batches; there is no reconciler to be paused and
no tick to be broken. Do not debug sidekiq for this. Use the manual procedure
in [What to do instead](#what-to-do-instead).

**Nothing happened after I approved the plan** — same cause as above. The
approval gate is real; the thing it gates was never built.

**Instances don't pick up the new version after the pointer flip** — the
pointer move is the platform's whole side of the operation; convergence is the
agent's. Check the instance is heartbeating at all (Tutorial 03
troubleshooting), then force one forward with
`system_refresh_instance_modules({ instance_id })` and re-read its
`running_module_digests`. If a `sync_modules` task is queued but the digest
never changes, the module likely has no mountable artifact — confirm the
target version carries an `oci_digest`.

**Rollback target refused** — `system_rollback_module_version` returns "has no
mountable artifact" when the version you named is missing an `oci_digest`, or
its recorded artifact size is below `system.module_publish.min_artifact_bytes`.
A version with an *unknown* size is accepted (old rows predate size recording),
so this is a real artifact problem, not a metadata gap. Republish a good build.

**Rollback doesn't fully restore previous version** — a `retired` version is
still kept for rollback/audit, so retiring the old version doesn't break
rollback by itself — but if the version **row was deleted** outright, rollback
fails because the version no longer resolves. Keep the prior version row (even
`retired`) until you're certain you'll never roll back.

## What's next

- **[Tutorial 07 — CVE response](./07-cve-response.md)** — CVE remediation
  routes to `rolling_module_upgrade` as its remediation step, so it inherits
  this gap: the CVE lane plans and does not roll out. See
  [`cve-response.md`](../runbooks/cve-response.md) Phase 6.
- **[Tutorial 08 — Instance pools](./08-instance-pool.md)** — for
  stateless workloads, **pool replacement** is the one blast-radius bound that
  actually works today: terminate old instance, claim a fresh new-version one
  from the pool.
- **[`SKILL_EXECUTORS.md`](../SKILL_EXECUTORS.md)** §`rolling_module_upgrade` —
  full skill input/output reference.
- **[`FLEET_SENSORS.md`](../FLEET_SENSORS.md)** — `system.fleet_rolling_upgrade`
  intervention policy.

_Last verified: 2026-06-03_
