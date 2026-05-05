# Example 06 — Instance pool for bursty batch workloads (slice 7)

End-to-end walkthrough: pre-warmed `System::InstancePool` keeps 5 ephemeral Docker hosts ready; an operator claims them in <30 s for a burst, releases when done. Companion seed: `db/seeds/example_instance_pool.rb` (Phase 3).

**Goal:** demonstrate slice 7 instance pools cutting bursty workload provisioning latency from 5–10 min to <30 s.

**Audience:** ML engineers, batch-processing operators, CI/CD platform owners.

**Prerequisites:**
- A NodeTemplate configured for ephemeral Docker hosts (`docker-engine` module assigned, `lifecycle_class: ephemeral`)
- Provider quota for ≥10 instances of the chosen instance type

## Step 1 — Create the pool

```javascript
platform.system_create_instance_pool({
  name: "ml-training-pool",
  description: "Warm pool for daily ML training bursts",
  template_id: "<ml-docker-template>",
  provider_region_id: "region-aws-us-east-1",
  provider_instance_type_id: "type-g4dn-xlarge",      // GPU instance
  target_size: 5,
  min_size: 2,
  max_size: 10,
  warmup_grace_seconds: 600
})
// → { instance_pool: { id: "pool-ml-1", status: "warming", member_count: 0, ... } }
```

The reaper job (`system_pool_replenish`, Sidekiq cron, every 60 s) sees `member_count < target_size` and starts provisioning 5 instances.

## Step 2 — Wait for warm-up

```javascript
platform.system_get_instance_pool({ id: "pool-ml-1" })
// → {
//      instance_pool: { ..., status: "warming", member_count: 5 },
//      members: [
//        { instance_id, status: "warming", warming_started_at, ... },
//        ... 4 more
//      ]
//    }
```

After ~5 min (typical bootstrap latency × 5 instances, parallel):

```javascript
// → {
//      instance_pool: { ..., status: "ready", member_count: 5 },
//      members: [
//        { instance_id, status: "ready", warmed_at, ... },
//        ... 4 more
//      ]
//    }
```

All 5 are warm and ready to claim.

## Step 3 — Claim 3 instances for a burst

```javascript
// Atomic claim — uses SELECT FOR UPDATE SKIP LOCKED
const job1 = platform.system_acquire_pooled_instance({
  pool_id: "pool-ml-1",
  acquired_by: "ml-team-alice",
  acquired_for: "training-run-2026-05-04-A"
})
// → { instance: { id, status: "running", ... }, claim_id }
// elapsed: <30 s (because instance was already warm)

const job2 = platform.system_acquire_pooled_instance({ pool_id: "pool-ml-1", ... })
const job3 = platform.system_acquire_pooled_instance({ pool_id: "pool-ml-1", ... })

// Pool now has member_count: 2 (3 of 5 claimed)
// Reaper sees deficit; starts provisioning 3 replacements
```

## Step 4 — Use the claimed instances

The claimed instances are standard NodeInstances — use them like any other:

```javascript
// Run docker on the claimed instance
platform.docker_pull_image({ host_id: "<host-id-on-claimed-instance>", image: "tensorflow:latest-gpu" })
platform.docker_create_container({
  host_id: "<host-id>",
  image: "tensorflow:latest-gpu",
  command: ["python", "/training-script.py"],
  env: ["DATASET_S3=..."],
  detach: true
})
```

Or SSH for break-glass:

```bash
ssh ops@<instance-host-address>
# (host-address is the SDWAN /128 from system_get_instance)
```

## Step 5 — Watch replenishment

While your training jobs run, the reaper provisions replacements:

```javascript
platform.recent_events({ kind_prefix: "pool", limit: 50 })
// → events: [
//      { kind: "pool.member_provisioned", pool_id, instance_id, ... },
//      { kind: "pool.member_warmed", pool_id, instance_id, ... },
//      ... (after each warm-up)
//    ]
```

## Step 6 — Terminate when done

After the training job completes:

```javascript
platform.system_terminate_instance({ id: "<claimed-instance-id>" })
// → cascade FK cleanup; pool reaper provisions a replacement
```

For ephemeral workloads, **prefer terminate over return** — the instance is stateless after the job; the pool keeps replenishing fresh members.

## Step 7 — Drain the pool when no longer needed

```javascript
platform.system_drain_instance_pool({
  id: "pool-ml-1",
  terminate_members: true                              // destroy all warm members
})
// → { drained: true, terminated_count: 5 }

// Then optionally delete the pool record itself:
platform.system_delete_instance_pool({ id: "pool-ml-1" })  // ⚠️ aspirational
```

## Sizing for your workload

The right `target_size` depends on your peak claim rate:

| Pattern | Recommended target_size |
|---|---|
| 1 claim / hour (low burst) | min_size = 1, target_size = 2, max_size = 5 |
| 5 claims / minute (CI runner) | min_size = 5, target_size = 10–15, max_size = 25 |
| Burst-then-quiet (ML training) | Use **scheduled scale-up**: increase target_size before the burst window via cron/MCP, decrease after |

Cost note: warm members cost the same as active members. Higher target_size = lower latency + higher idle cost. Tune based on whether latency or cost matters more for your use case.

## What to watch

- **`PoolEmptyError`** during burst — increase target_size or pre-bake a NodePlatform image to reduce W (warmup latency)
- **Members stuck `warming` >10 min** — bootstrap failed. Use `attribute_failure` skill to diagnose.
- **Reaper not replenishing** — check Sidekiq queue, restart `powernode-worker@default` if backed up
- **Members drift in version** — pool members are provisioned from the pool's Template; if the template gets a new module assignment, only NEW members get it. Existing warm members keep the old version until claimed-and-replaced.

## Related

- [`runbooks/instance-pool-tuning.md`](../runbooks/instance-pool-tuning.md) — full sizing + tuning reference
- [`USE_CASE_MATRIX.md`](../USE_CASE_MATRIX.md) — use cases 4 (bursty batch) + 5 (CI runner pool)
- [`example 04`](./04-rolling-module-upgrade.md) — for upgrading the underlying template
