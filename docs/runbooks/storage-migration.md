# Storage Migration Runbook

> Status: active

Operator procedure for moving a stateful component's data from one
`ProviderVolume` to another — end to end through the MCP tool surface — plus the
ancillary storage operations an operator reaches for during a migration: cancel,
failure triage, chown status/retry, and pre-flight NFS export probing.

**Audience:** storage / SRE operators running a volume-to-volume data move
(e.g. relocating `/var/lib/postgresql` to a larger or faster volume), and
on-call SREs triaging a stuck or failed migration.

**Prerequisites:**
- A **source** and a **target** `ProviderVolume` already registered for the
  account (the target must differ from the source). Register/probe first with
  `system_create_volume` / `system_test_nfs_export`.
- Permissions: `system.platform.read` + `system.platform.scale` for the
  migration lifecycle; `system.storage.read` + `system.storage.assignments.update`
  for the chown actions; `system.volumes.*` for volume CRUD.
- The target NodeInstance is `running` with a healthy agent (the data copy runs
  on the on-node `powernode-agent`).

**Runtime:** varies by data size — the control-plane transitions are sub-second;
the `rsync` step dominates and scales with the component's on-disk footprint.

---

## Concept refresher

The platform records **intent + a plan**; the on-node Go agent performs the
actual copy. A `StorageMigration` walks a hand-rolled state machine
(`app/models/system/storage_migration.rb`):

```
planned → approved → preparing → syncing → verifying → cutover → completed
                          │          │          │          │
                          └──────────┴──────────┴──────────┴────▶ failed (terminal)

planned / approved / preparing ──cancel──▶ cancelled (terminal)
```

- `failed` is reachable from **any** non-terminal state.
- `cancelled` is reachable **only** from `planned` / `approved` / `preparing`
  (i.e. before the sync starts).
- On `cutover → completed`, `promote_target_binding!` swaps the instance's
  `storage_volume` binding from source to target.

For the full architecture see [../STORAGE_SUBSYSTEM.md](../STORAGE_SUBSYSTEM.md).

## Quick reference

| Phase | What happens | MCP entry point |
|---|---|---|
| 1. Plan | Persist a `planned` StorageMigration + plan | `system_migrate_storage_component` |
| 2. Approve | `planned → approved`; agent may begin | `system_approve_storage_migration` |
| 3. Prepare / Sync / Verify | Agent copies + verifies; reports progress + phase | `system_report_storage_migration_progress` |
| 4. Cutover → Complete | Bind instance to target volume | `system_report_storage_migration_progress` (`status: "completed"`) |
| — Monitor | Read status, bytes, audit log | `system_get_storage_migration` / `system_list_storage_migrations` |
| — Cancel (pre-sync) | `→ cancelled` | `system_cancel_storage_migration` |

---

## Phase 0 — Pre-flight (optional) ✅

If the target is an NFS volume you have not yet registered, probe it first — this
runs DNS + TCP 111/2049 + `showmount -e` and does **not** mount, so it's safe to
call from chat:

```javascript
platform.system_test_nfs_export({
  server: "nfs-prod-01.powernode.internal",
  export_path: "/exports/pg"          // optional; omit to list all exports
})
// → { probe: { dns_resolved, port_111_open: true, port_2049_open: true,
//              exports: [{ path: "/exports/pg", ... }], export_path_match: true } }
```

**Expected outcome:** `port_2049_open: true` and (if you passed `export_path`)
`export_path_match: true`. If either port is closed, fix reachability before
recording a volume — see Failure modes.

Confirm both volumes exist and the target is distinct:

```javascript
platform.system_get_volume({ id: "<source-volume-id>" })
platform.system_get_volume({ id: "<target-volume-id>" })
// → each: { volume: { id, name, status, volume_type: { volume_type }, ... } }
```

---

## Phase 1 — Plan the migration ✅

```javascript
platform.system_migrate_storage_component({
  node_instance_id: "<instance-id>",     // instance whose component is moving
  source_volume_id: "<source-volume-id>",
  target_volume_id: "<target-volume-id>",
  role: "postgres"                        // determines source/target subpaths
})
// → { storage_migration: { id, status: "planned", role,
//        source_subpath, target_subpath, ... } }
```

This persists a `StorageMigration` in status `planned` and returns the serialized
row. The `plan` (visible via `system_get_storage_migration`) records
`deployment_name`, `role`, the source/target `{ volume_id, transport, subpath }`,
the `snapshot_path`, and an `agent_contract` whose `steps` are the recipe the
on-node agent follows: `mount_target, snapshot, rsync, verify, cutover,
unmount_source`.

**Expected outcome:** `status: "planned"`. No data has moved yet — only intent is
recorded.

**What to watch:**
- `source` and `target` must differ — the model validates this and the tool
  rejects equal IDs (see Failure modes).
- `role` is required; it selects the on-volume subpath layout.

---

## Phase 2 — Approve ✅

Approval is the gate that authorizes the on-node agent to begin. It is only legal
from `planned`.

```javascript
platform.system_approve_storage_migration({ id: "<migration-id>" })
// → { storage_migration: { id, status: "approved", approved_at, ... } }
```

**Expected outcome:** `status: "approved"`, `approved_at` set. An audit entry
`Approved by <operator>` is appended to the migration's `audit_log`.

---

## Phase 3 — Monitor prepare / sync / verify ⚠️

After approval the agent works the `agent_contract` steps and advances the
migration through `preparing → syncing → verifying`, reporting byte progress as it
goes. There is **no** separate "prepare"/"sync" MCP action — every post-approval
phase transition flows through `system_report_storage_migration_progress` with a
`status:` that must be a legal next state. (In v1 the operator overseeing the
rsync may drive these transitions; the same call is what the agent uses.)

```javascript
// Advance approved → preparing
platform.system_report_storage_migration_progress({
  id: "<migration-id>", status: "preparing", note: "mounting target + snapshot"
})

// Advance preparing → syncing and report bytes as the rsync runs
platform.system_report_storage_migration_progress({
  id: "<migration-id>", status: "syncing",
  bytes_copied: 1048576, bytes_total: 53687091200, note: "rsync started"
})

// Subsequent progress pings (no status change — just byte counters)
platform.system_report_storage_migration_progress({
  id: "<migration-id>", bytes_copied: 26843545600, bytes_total: 53687091200
})

// Advance syncing → verifying
platform.system_report_storage_migration_progress({
  id: "<migration-id>", status: "verifying", bytes_verified: 53687091200,
  note: "checksum verify"
})
```

Watch progress at any time:

```javascript
platform.system_get_storage_migration({ id: "<migration-id>" })
// → { storage_migration: { status, bytes_copied, bytes_total, bytes_verified,
//        audit_log: [ ... ], plan: { ... }, ... } }

// Or scan all active migrations for the account:
platform.system_list_storage_migrations({ active_only: true })
// → { storage_migrations: [ { id, status, role, node_instance_id, ... } ] }
```

**Expected outcome:** status walks `preparing → syncing → verifying`; `bytes_copied`
approaches `bytes_total`; each transition appends an audit entry. A
progress-only call (no `status`) updates counters without changing state.

---

## Phase 4 — Cutover → completed ✅

When verify passes, advance `verifying → cutover`, then `cutover → completed`.
The `→ completed` transition fires `promote_target_binding!`, which rewrites
`NodeInstance.config["storage_volume"]` from the source to the target volume so
post-restart agent boots and heartbeat fetches mount the **new** home.

```javascript
platform.system_report_storage_migration_progress({
  id: "<migration-id>", status: "cutover", note: "switching binding"
})

platform.system_report_storage_migration_progress({
  id: "<migration-id>", status: "completed", note: "cutover landed"
})
// → { storage_migration: { status: "completed", completed_at, ... } }
```

**Expected outcome:** `status: "completed"`, `completed_at` set. Verify the
binding actually swapped:

```javascript
platform.system_get_instance({ id: "<instance-id>" })
// → instance.config.storage_volume.volume_id === "<target-volume-id>"
```

If the binding still shows the source volume, `promote_target_binding!` hit an
error and logged a warning instead of raising — see "Half-cutover" in Failure
modes.

---

## Cancelling (pre-sync only) ⚠️

A migration can be cancelled **only** while `planned`, `approved`, or `preparing`:

```javascript
platform.system_cancel_storage_migration({
  id: "<migration-id>", reason: "wrong target volume selected"
})
// → { storage_migration: { status: "cancelled", cancelled_at, ... } }
```

**Expected outcome:** `status: "cancelled"`. Once the sync has started
(`syncing` or later) cancellation is refused — let it finish or drive it to
`failed` (Failure modes).

---

## Chown status / retry (ownership operations) ⚠️

Changing a mount's owner (`system_assign_storage_owner`) triggers a recursive
on-node `chown`. Inspect and retry it with:

```javascript
// Inspect chown progress on one assignment
platform.system_storage_chown_status({ storage_assignment_id: "<assignment-id>" })
// → { chown_state, chown_previous_uid, chown_task_id, chown_last_error,
//     effective_export_uid, ... }

// Re-dispatch a failed / manual_required chown
platform.system_storage_chown_retry({ storage_assignment_id: "<assignment-id>" })
// → { storage_assignment_id, chown_state: "pending"|"running", chown_task_id }

// Audit which assignments are stuck across the fleet
platform.system_list_storage_assignments_by_owner({ chown_state: "failed" })
// → { assignments: [ { id, mount_path, owner_kind, chown_last_error, ... } ] }
```

**Expected outcome:** `chown_state` moves `failed`/`manual_required → pending →
running → complete`. Retry is **only** valid from `failed` or `manual_required`.
For a provider the platform cannot reach (external NFS), chown someone manually,
then flip the assignment with the escape hatch `force_complete: true`:

```javascript
platform.system_storage_chown_retry({
  storage_assignment_id: "<assignment-id>", force_complete: true
})
// → { storage_assignment_id, chown_state: "complete", forced: true }
```

---

## Failure modes

| Symptom | Cause | Diagnosis + remediation |
|---|---|---|
| `Cannot cancel — sync already in progress` | `system_cancel_storage_migration` called once status is `syncing`/`verifying`/`cutover` | Cancel is pre-sync only (`StorageMigration#cancel!` raises `ArgumentError` for later states). Let the sync finish, or drive it to `failed` via `report_progress` with `status: "failed"`. |
| `Migration create failed: …` / `Source and target must differ` | `source_volume_id == target_volume_id` | The model's `source_not_target` validation and the tool both reject this. Pass a distinct target volume. |
| `Source/target volume not found` | A volume id is wrong or belongs to another account | Volumes are account-scoped. Re-check ids with `system_list_volumes` / `system_get_volume`. |
| `Cannot approve in status=<x>` | `system_approve_storage_migration` on a non-`planned` row | Approve is only legal from `planned`. If it's already `approved`/past, proceed to Phase 3; if terminal, start a new migration. |
| `Illegal transition <a> → <b>` | `report_progress` `status:` is not a legal next state | Follow the forward path `approved→preparing→syncing→verifying→cutover→completed` (or `→failed` from any non-terminal). Read current status with `system_get_storage_migration`. |
| **Half-cutover** — status `completed` but instance still bound to source | `promote_target_binding!` raised internally and was caught (it logs a warning + audit `promote_target_binding! warning: …` rather than re-raising) | Inspect the migration's `audit_log` for the warning and `system_get_instance` → `config.storage_volume.volume_id`. Re-issue the binding (re-attach the target) so the instance mounts the migrated data; the data itself is already at the target. |
| Migration stuck in `failed` (terminal) | `mark_failed!` / a `status: "failed"` report landed it there | `failed` is terminal — there is no resume. Read `error_message` + `audit_log` to root-cause, then create a **new** migration with `system_migrate_storage_component`. |
| chown stuck `failed` / `manual_required` | On-node `chown` failed, or provider is external/unmanaged (object stores are no-ops; external NFS → `manual_required`) | `system_storage_chown_status` for `chown_last_error`; fix the cause and `system_storage_chown_retry`. For unreachable providers, chown manually then retry with `force_complete: true`. |
| `system_test_nfs_export` shows `port_2049_open: false` or empty `exports` | NFS server unreachable, firewall blocking 111/2049, or export not advertised | Fix network/firewall/exports on the server before `system_create_volume`. `export_path_match: false` means the export path you expect isn't advertised. |
| `system_delete_volume` refused | Volume still attached | `delete` requires the volume be `available`/`error` **and** unattached (`ProviderVolume#can_delete?`). `system_detach_volume` first, then delete. |

---

## Related docs

- [../STORAGE_SUBSYSTEM.md](../STORAGE_SUBSYSTEM.md) — storage subsystem
  architecture (data model, the eight services, full state machine, MCP surface)
- [node-provisioning.md](./node-provisioning.md) — provision the NodeInstance the
  volume mounts onto
- [README.md](./README.md) — runbook index (audience + prereqs per runbook)
- [../ARCHITECTURE.md](../ARCHITECTURE.md) — fleet substrate overview

_Last verified: 2026-06-26_
</content>
