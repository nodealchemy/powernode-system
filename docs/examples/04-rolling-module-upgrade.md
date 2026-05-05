# Example 04 — Rolling module upgrade with canary + circuit breaker

End-to-end walkthrough: upgrade `nginx` from 1.24.0 → 1.26.0 across a fleet of 50 instances using `rolling_module_upgrade` skill, with batch-by-batch health checks and automatic circuit-breaker if too many fail. Companion seed: `db/seeds/example_rolling_upgrade.rb` (Phase 3).

**Goal:** demonstrate batched fleet upgrades with canary protection and operator-overridable circuit breakers.

**Audience:** SREs running rolling deploys; release engineers tuning canary thresholds.

**Prerequisites:**
- Existing fleet of 50+ NodeInstances assigned to a Template with `nginx` 1.24.0
- New `nginx` 1.26.0 module version published + promoted to `blessed`
- Operator with `system.fleet_rolling_upgrade` approval rights

## Step 1 — Identify the upgrade target

```javascript
// Find the current + target versions
platform.system_list_module_versions({ module_name: "nginx" })
// → { versions: [
//      { id: "v-1.24.0", lifecycle_state: "live", ... },
//      { id: "v-1.26.0", lifecycle_state: "blessed", ... }
//    ] }

platform.system_list_instances({ template_id: "<edge-template>" })
// → { instances: [{ id, status: "running", running_module_digests: { nginx: "sha256:..." } }, ...50] }
```

## Step 2 — Plan the upgrade (dry-run via skill)

```javascript
platform.execute_skill({
  skill: "system-rolling-module-upgrade",
  inputs: {
    template_id: "<edge-template>",
    module_id: "<nginx-module-id>",
    target_version_id: "v-1.26.0",
    batch_pct: 20,                          // 20% per batch = 10 instances
    max_consecutive_failures: 2,            // trip circuit after 2 unhealthy in a row
    health_timeout_sec: 300                 // wait 5 min for each batch to stabilize
  }
})
// → {
//      total_instances: 50,
//      batch_size: 10,
//      batch_count: 5,
//      estimated_total_seconds: 1500,
//      circuit_breaker: { max_consecutive_failures: 2, tripped_after_seconds: null },
//      batches: [
//        { index: 0, instance_ids: [...10], phase: "pending" },
//        ...4 more
//      ]
//    }
```

## Step 3 — Approve the plan

`system.fleet_rolling_upgrade` is `require_approval` per the Fleet Autonomy intervention policy. The skill execution creates an `ApprovalRequest`:

1. Operator opens `/app/approvals` UI
2. Reviews the plan: 50 instances in 5 batches of 10, ~25 min total
3. Optional: edit `batch_pct` (more conservative for Tier-1 services) or `max_consecutive_failures` (1 for stricter stop-on-fail)
4. Click **Approve**

Once approved, the autonomy reconciler picks up the plan on its next 60s tick and starts executing.

## Step 4 — Watch progress

```javascript
// Tail the upgrade events
platform.recent_events({
  kind_prefix: "module.upgrade",
  limit: 100
})
// → events: [
//      { kind: "module.upgrade.batch_started", batch_index: 0, instance_count: 10, ... },
//      { kind: "module.upgrade.instance_started", instance_id, target_version, ... },
//      { kind: "module.upgrade.instance_health_check", instance_id, healthy: true, ... },
//      { kind: "module.upgrade.batch_completed", batch_index: 0, healthy_count: 10, failed_count: 0, ... },
//      { kind: "module.upgrade.batch_started", batch_index: 1, ... }
//    ]
```

Or via UI: `/app/system/operations` → "Active rolling upgrades" panel shows batch status + per-instance progress.

## Step 5 — Circuit breaker scenario

If 2 instances in a batch fail their health checks (e.g., new nginx config has a syntax error), the circuit breaker trips:

```javascript
// Reconciler emits:
{ kind: "module.upgrade.circuit_breaker_tripped",
  batch_index: 1,
  failed_instance_ids: ["...", "..."],
  reason: "max_consecutive_failures (2) exceeded" }

// And creates a fresh ApprovalRequest:
{ approval_request: {
    type: "rolling_upgrade_continuation",
    options: ["continue_anyway", "rollback_completed_batches", "abort"]
}}
```

Operator decides:
- **continue_anyway**: ignore the circuit, proceed to remaining batches (use when failures are transient)
- **rollback_completed_batches**: rollback already-upgraded instances to v1.24.0 (use when the new version has a fundamental flaw)
- **abort**: stop here; manually investigate the failed instances

## Step 6 — Verify upgrade

```javascript
platform.system_drift_report({ template_id: "<edge-template>" })
// → { drift: false }   (all 50 instances now running v1.26.0)

// Or per-instance:
platform.system_get_instance({ id: "<sample-instance>" })
// → { instance: { running_module_digests: { nginx: "sha256:<v1.26-digest>", ... } } }
```

## Step 7 — Extract a learning

```javascript
platform.create_learning({
  title: "nginx 1.24 → 1.26 rolling upgrade — batch_pct=20% works for edge fleet",
  category: "best_practice",
  content: "50-instance edge fleet: 20% batches × 5 batches × ~5min health window = 25 min total. Zero circuit breaker trips. Recommend keeping batch_pct=20% for similar-sized fleets; reduce to 10% for Tier-1 services with smaller blast radius tolerance.",
  tags: ["rolling-upgrade", "nginx", "batch-sizing"]
})
```

Future similar upgrades surface this learning in the `rolling_module_upgrade` skill's reasoning.

## What to watch

- **Health check accuracy matters** — the default check is "instance heartbeats with new module digest in `running_module_digests`". For app-level health (does nginx actually serve traffic?), add a custom health probe.
- **Pre-warmed pools cut blast radius** — replace upgraded instances with fresh-from-pool instances of the new version (instead of in-place upgrade) for stateless workloads. See [`runbooks/instance-pool-tuning.md`](../runbooks/instance-pool-tuning.md).
- **Circuit breaker is your friend** — keep `max_consecutive_failures: 2` low. The cost of a paused upgrade is small; the cost of a fleet-wide bad rollout is large.

## Related

- [`SKILL_EXECUTORS.md`](../SKILL_EXECUTORS.md) — `rolling_module_upgrade` skill
- [`FLEET_SENSORS.md`](../FLEET_SENSORS.md) — `system.fleet_rolling_upgrade` intervention policy
- [`runbooks/cve-response.md`](../runbooks/cve-response.md) — CVE response uses this skill for remediation
- [`runbooks/module-authoring.md`](../runbooks/module-authoring.md) — for authoring the new module version
