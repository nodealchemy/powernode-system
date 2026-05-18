# Migration Framework — Extension Developer Guide

This guide explains how an extension author declares its resources as
**migratable** so they participate in cross-peer migration + duplication
via the Decentralized Federation Migration framework.

The framework lives at `System::Migrations::*` (model, PlanComposer,
ConflictDetector, ApplyExecutor) and is driven by per-extension
`federation_inventory.yaml` files.

Plan reference: Decentralized Federation §F + P5 + Locked Decision #14.

---

## TL;DR

To make a model migratable:

1. Add the model's "kind name" to your extension's `federation_inventory.yaml`
2. Declare its dependencies + duplication / migration semantics
3. (Optional) Implement a custom per-kind serializer if AR's `.attributes`
   would leak sensitive fields

That's it. The framework handles plan composition, UUID semantics,
conflict detection, and the destination-side write transaction.

---

## UUID semantics: duplicate vs migrate (Locked Decision #14)

Two operations, with **opposite** UUID semantics — pick the right one
for your use case:

```mermaid
flowchart TD
    Op[Operator at Peer A] --> Compose[PlanComposer.compose!<br/>operation: migrate OR duplicate<br/>root_kind + root_id<br/>destination_peer]
    Compose --> Walk[Walk AR has_many<br/>reflections per inventory]
    Walk --> Plan[Migration row + MigrationPlanStep rows<br/>status: planned]

    Plan --> OpMode{operation}
    OpMode -->|migrate| MigrateBranch[Each step's resource_id<br/>= source UUID<br/>payload preserves id]
    OpMode -->|duplicate| DupBranch[Each step's resource_id<br/>= fresh UUIDv7<br/>payload metadata.duplicated_from<br/>= source UUID]

    MigrateBranch --> Detect[ConflictDetector.scan!<br/>(unique-index collisions)]
    DupBranch --> Detect
    Detect --> Decide{conflicts?}
    Decide -->|none| Apply[ApplyExecutor.apply!<br/>at destination peer]
    Decide -->|present| Policy[Operator picks per-step<br/>conflict_policy:<br/>skip_if_exists / overwrite / fail]
    Policy --> Apply
    Apply --> Result{success?}
    Result -->|yes| Done[Migration status: applied]
    Result -->|migrate only| Cleanup[Source-side cleanup<br/>(delete originals after ack)]
    Cleanup --> Done
    Result -->|no| Failed[Migration status: failed<br/>(transaction rolled back)]
```

### `migrate` — transfer ownership, **UUID is preserved**

The source's record is deleted after the destination acknowledges.
At any instant exactly one peer holds the UUID (modulo the in-flight
ack window). Use this when the record's identity is foundational and
moving it should not produce a new logical instance.

```ruby
result = System::Migrations::PlanComposer.compose!(
  account: alice_account,
  operation: "migrate",
  root_kind: "account",
  root_id: account_uuid,
  destination_peer: peer_b
)
# Each plan_step's resource_id == source record's UUID.
# Source-side cleanup removes the original after destination acks.
```

### `duplicate` — copy with a fresh identity, **UUID is rewritten**

The composer generates a **fresh UUIDv7 at the destination** for every
record in the plan. Source UUID is preserved in the new record's
`metadata.duplicated_from` lineage so origin is traceable, but the two
records are independent from creation. Use this for template forking,
archival snapshots, or distribution of reference data.

```ruby
result = System::Migrations::PlanComposer.compose!(
  account: alice_account,
  operation: "duplicate",
  root_kind: "inventory_item",         # example: any duplicable kind your extension declares
  root_id: item_uuid,
  destination_peer: peer_b
)
# Each plan_step's resource_id is a fresh UUIDv7 — NOT the source's id.
# The source's id appears at payload.metadata.duplicated_from.uuid.
```

**Why this rule:** same UUID held simultaneously by two peers is treated
as an integrity bug — the federation framework guarantees a single home
per UUID at any moment. Eliminates an entire class of "two replicas
diverged" problems before they can occur. See plan §F + LD #14.

---

## federation_inventory.yaml schema

Each extension drops a `federation_inventory.yaml` at its root:

```yaml
# Example federation_inventory.yaml from a hypothetical extension
extension: inventory
exportable_kinds:
  - kind: skill
    dependencies: [learning, knowledge_base_entry]
    duplicable: true
    migratable: false
    metadata:
      sensitive_fields: [api_secret]

  - kind: inventory_item
    dependencies: [skill]
    duplicable: true
    migratable: true
```

**Fields:**

- `kind` (required) — the resource_kind string used in URLs + Migration rows.
  Must match the model's lowercase-snake-case-of-`name.demodulize`
  (`Ai::Skill` → `"skill"`, `Inventory::Item` → `"inventory_item"`,
  `System::PlatformDeployment` → `"platform_deployment"`).

- `dependencies` (optional, array) — other declared kinds that should be
  walked when this kind is the root of a migration. The PlanComposer
  uses AR has_many reflection to find related records of each dep kind.

- `duplicable` (default true) — when false, this kind cannot be the
  root of a `duplicate` operation. (Some kinds are inherently
  source-of-truth and should only be migrated, not copied.)

- `migratable` (default false) — when false, this kind cannot be the
  root of a `migrate` operation. Conservative default — most kinds are
  duplicable but not movable.

- `metadata` (optional) — free-form hash for future extension hooks
  (e.g. `sensitive_fields` for serializer filtering).

---

## Composing a migration plan

```ruby
result = System::Migrations::PlanComposer.compose!(
  account: alice_account,
  operation: "duplicate",  # or "migrate"
  root_kind: "inventory_item",
  root_id: "019fab...",
  destination_peer: peer_b,
  initiated_by_user: alice,
  dry_run: true
)

result.ok?         # => true
result.migration   # => System::Migration row, status="planned"
result.step_count  # => integer; total plan_steps created
```

The composer walks declared dependencies via AR `has_many` reflection.
For each related record found, it creates a `MigrationPlanStep` with
`action: "create"`. For `duplicate` plans, each step's `resource_id` is
a fresh UUIDv7 and the payload's `metadata.duplicated_from` records the
source's UUID. For `migrate` plans, `resource_id` and `payload["id"]`
preserve the source's UUID.

Dry-run mode (`dry_run: true`, the default) builds the plan but does
NOT apply anything at the destination. Inspect `migration.plan_steps.ordered`
to see what would happen.

---

## Detecting conflicts before apply

For `migrate` plans, secondary unique constraints (User.email,
NodeModule.name, etc.) may still collide at the destination even though
the PK does not. Run the detector before sending the plan:

```ruby
result = System::Migrations::ConflictDetector.scan!(migration: migration)

result.ok?            # => true
result.conflict_count # => integer
result.conflicts      # => array of conflict hashes
```

Each conflict hash:

```json
{
  "step_id": "019fab...",
  "resource_kind": "user",
  "resource_id": "019fac...",
  "constraint": "index_users_on_email",
  "columns": ["email"],
  "conflicting_record_id": "019fad...",
  "suggested_policy": "rename_with_suffix"
}
```

The detector scans every unique index on the destination model (other
than the PK) and reports collisions where the planned record's payload
matches an existing row's values.

For `duplicate` plans, secondary collisions are rare (the destination
hasn't seen this record before in any identity), but they can still
happen when the duplicated record has an identity-like field (e.g.,
email) that the destination has independently created.

If any conflicts exist, the operator decides how to proceed:

- **skip_if_exists** — drop the conflicting plan step
- **rename_with_suffix** — modify a unique field to avoid the collision
  (e.g. `alice@b` → `alice+peer-uuid@b`) — *deferred to v2*
- **overwrite** — destructively replace the destination row (rare)
- **fail** — abort the entire migration

---

## ApplyExecutor contract

The destination runs `System::Migrations::ApplyExecutor.apply!(migration:)`
to apply a transferring migration. One transaction wraps every step;
any error (unknown kind, save failure, conflict-policy `fail`, missing
link_local target, **or duplicate-plan PK collision per LD #14**) raises
`ApplyError` which triggers ActiveRecord rollback. The migration row
transitions to `failed` with the error captured.

Intentional outcomes (conflict-policy `skip_if_exists`, `overwrite`,
or `action: skip`) record themselves on the step and continue.

**PK-collision handling differs by operation:**

| Operation | Behavior on PK collision |
|---|---|
| `duplicate` | Hard error — composer should never emit a preserved UUID. Migration fails. |
| `migrate` | Apply the step's `conflict_policy`: skip / overwrite / fail. |

---

## What's NOT in v1

The following are explicitly deferred:

- **Polymorphic FK traversal** (`subject_id` + `subject_type` columns).
  The plan composer's reflection walk doesn't follow polymorphic
  belongs_to / has_many associations. Polymorphic models won't have
  their related records auto-walked; declare them explicitly as a
  dependency kind if the relationship needs to migrate.

- **JSONB-embedded UUID detection.** Many models stash record references
  inside JSONB columns (e.g. `metadata.referrer_id`). The v1 framework
  does NOT scan JSONB for embedded UUIDs. If your model relies on this
  pattern, add a `prepare_for_migration` callback that extracts these
  to first-class associations before migration.

- **Cross-version schema negotiation.** If two peers run different
  versions of an extension with diverging schemas, the migration may
  fail at apply time. The capability handshake will exchange schema
  versions in a future round.

- **Per-edge dependency resolution policy** (cascade vs link_local vs
  skip). v1 always cascades; future rounds add per-dep policy.

- **`rename_with_suffix` conflict policy.** Marked as a value but the
  ApplyExecutor returns a clear "not implemented in v1" error if a step
  uses it. Per-kind rename strategy is deferred.

- **Bidirectional sync.** This is a one-shot Migration operation, not
  a continuous-sync arrangement. Continuous sync requires a future
  `replication_pair` mapping table (P9 hypothetical) that links distinct
  local UUIDs across peers — preserves the single-home-per-UUID invariant
  while enabling identity-as-relation.

---

## Testing your model's participation

```ruby
RSpec.describe Inventory::Item do
  let(:account) { create(:account) }

  before do
    # Inject your kind into the InventoryRegistry
    registry = System::Federation::InventoryRegistry.new
    registry.register_kind(
      extension: "inventory", kind: "inventory_item",
      dependencies: [], duplicable: true, migratable: true,
      metadata: {}
    )
    System::Federation::InventoryRegistry.install_test_double(registry)
  end

  after { System::Federation::InventoryRegistry.install_test_double(nil) }

  it "is composable as a duplicate root with fresh UUID + lineage" do
    item = create(:inventory_item, account: account)
    result = System::Migrations::PlanComposer.compose!(
      account: account, operation: "duplicate",
      root_kind: "inventory_item", root_id: item.id
    )
    expect(result.ok?).to be true
    root_step = result.migration.plan_steps.find_by(step_order: 0)
    # LD #14: duplicate generates a fresh UUID; lineage in metadata
    expect(root_step.resource_id).not_to eq(item.id)
    expect(root_step.payload.dig("metadata", "duplicated_from", "uuid")).to eq(item.id)
  end

  it "is composable as a migrate root preserving UUID" do
    item = create(:inventory_item, account: account)
    result = System::Migrations::PlanComposer.compose!(
      account: account, operation: "migrate",
      root_kind: "inventory_item", root_id: item.id
    )
    expect(result.ok?).to be true
    root_step = result.migration.plan_steps.find_by(step_order: 0)
    # LD #14: migrate transfers ownership; UUID preserved
    expect(root_step.resource_id).to eq(item.id)
  end
end
```

---

## See also

- `docs/federation/SOCIAL_CONTRACT.md` — operator commitments (data hygiene #7)
- `docs/federation/MODULE_MANIFEST_SCHEMA.md` — sibling concept for module manifests
- `app/services/system/migrations/plan_composer.rb` — composer source
- `app/services/system/migrations/conflict_detector.rb` — detector source
- `app/services/system/migrations/apply_executor.rb` — apply executor source
- `app/models/system/migration.rb` — state machine
- `app/models/system/migration_plan_step.rb` — per-step record
