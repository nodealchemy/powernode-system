# Storage Subsystem — Architecture

> Status: active

The storage subsystem is the system extension's **data plane for stateful
workloads**: it provisions backing volumes, mounts them onto NodeInstances over
the SDWAN overlay, owns the Unix-identity (chown) model for on-disk files, and
moves a stateful component's data from one volume to another without losing the
`(deployment, role)` binding. It sits one layer below the runtime modules in the
fleet substrate — a `docker-engine` or `k3s-server` module runs the workload;
the storage subsystem keeps that workload's persistent state where it belongs.

This document is the concept/architecture reference. For the operator procedure
to run a migration end-to-end, see
[runbooks/storage-migration.md](./runbooks/storage-migration.md). For the broader
substrate, see [ARCHITECTURE.md](./ARCHITECTURE.md).

---

## Where it sits

```
Operator / AI agent
   │  MCP (system_* storage actions)  +  REST (/api/v1/system/.../volumes, storage_*)
   ▼
Control plane (Rails 8)
   ├─ ProviderVolume / ProviderVolumeType / ProviderVolumeMember  (backing storage)
   ├─ StorageAssignment      (a mount of a storage onto a NodeInstance)
   ├─ StorageCredential / MountEncryptionKey  (per-instance access + at-rest keys)
   └─ StorageMigration       (in-flight volume-to-volume data move)
   │
   │  System::Task rows (command: "storage.*")  — pull-based task lease
   ▼
On-node powernode-agent (Go)
   mounts / unmounts, writes exports.d + samba users, runs find/chown + rsync
```

The platform never pushes to a node. Every side effect — mount, unmount, NFS
export write, Samba user creation, chown, rsync — is enqueued as a
`System::Task` (`app/models/system/task.rb`) that the on-node agent leases over
its mTLS `node_api` channel and POSTs results back. The control-plane models
hold the desired state; the agent reconciles the node toward it.

**Owning AI agent.** The autonomy surface of this plane belongs to the
**Storage Manager** (`db/seeds/system_storage_manager_agent.rb`, HIER-P2C —
operator guide [STORAGE_MANAGER_AGENT.md](./STORAGE_MANAGER_AGENT.md)), not
Fleet Autonomy: the `storage_assignment_drift_sensor` lane gates under it
(`system.storage_assignment_reconcile`), `RestoreVolumeExecutor` binds to it
(`system.restore_volume`), and it carries the agent-shape twin of the snapshot
delete gate (`system.volume_snapshot_delete`). Its `tool_access.tool_families`
is the MCP surface tabulated below (minus the node agent's own
`system_report_storage_migration_progress`) plus the two instance reads, and its
approval chain (`Storage Manager Actions`, 8h, reject on timeout) is where those
two gated verbs wait. The migration verbs are NOT gated: `declare_action` for
`system_approve_storage_migration`, `system_cleanup_storage_migration`,
`system_revert_storage_migration_binding`, `system_cancel_storage_migration` and
`system_migrate_storage_component` carries `mutating: true` and no
`action_category`, so `BaseTool#gated_action?` is false and they execute
immediately — nothing about a migration ever parks on that chain. Placement and
capacity questions hand off to the Capacity Manager, node lifecycle to Fleet
Autonomy.

---

## Data model

### Backing volumes — `ProviderVolume`

`app/models/system/provider_volume.rb` is the unit of backing storage. Key
shape:

- `STATUSES = creating, available, in-use, deleting, deleted, error`.
- `belongs_to :volume_type` (`System::ProviderVolumeType`), `:provider_region`,
  `:availability_zone`, and optionally `:node_instance` (the attached host).
- Attachment is modeled directly: `attach_to!(instance, device_name)` flips
  `status` to `in-use` and sets `node_instance_id`; `detach!` reverses it.
  Predicates `can_attach?` / `can_detach?` / `can_delete?` / `can_snapshot?`
  gate the transitions (e.g. `can_delete?` requires `available || error` **and**
  unattached).
- RAID is supported via `ProviderVolumeMember` (`app/models/system/provider_volume_member.rb`):
  `RAID_LEVELS = [0, 1]` (0 = striping, 1 = mirroring), with `raid_capacity` /
  `active_member_count` / `has_minimum_members?` helpers.

### Volume types / transports — `ProviderVolumeType`

`app/models/system/provider_volume_type.rb` carries
`VOLUME_TYPES = gp2 gp3 io1 io2 st1 sc1 standard ssd hdd nfs iscsi smb custom`
— AWS-EBS-derived tiers, generic `ssd`/`hdd` tiers, the network-filesystem
transports `nfs`/`iscsi`/`smb`, and `custom` as a catch-all. When the subsystem
needs a **mount transport** it reads `volume_type.volume_type` and maps it: the
network transports `nfs`/`smb`/`iscsi` mount as themselves; everything else
(EBS tiers, ssd/hdd, custom) mounts as a local block `device` (see
`StorageMigration#promote_target_binding!`).

### Mounts — `StorageAssignment`

`app/models/system/storage_assignment.rb` is one mount of a storage onto one
NodeInstance at a `mount_path`. It carries:

- `STATUSES = pending, provisioning, mounted, degraded, unmounting, failed, disabled`.
- `ENCRYPTION_MODES = inherit, none, fscrypt, luks, client_side_aes`.
- The **ownership model**: `OWNER_KINDS = service_user, operator, nobody, root`.
  Non-service owners take static numeric IDs from `BASELINE_UIDS`
  (`operator → 1000`, `nobody → 65534`, `root → 0`); a `service_user` owner
  resolves to a platform-allocated UID in the `70000..99999` range.
- The **chown state**: `CHOWN_STATES = complete, pending, running, failed, manual_required`,
  plus `chown_previous_uid/gid`, `chown_task_id`, `chown_started_at`,
  `chown_completed_at`, `chown_last_error`. During an in-flight chown the
  assignment exposes `effective_export_uid/gid` (the **previous** owner) so NFS
  exports keep serving the old IDs and consumers don't take an `EACCES` storm
  while the agent rewrites ownership.
- Associations to `StorageCredential` and `MountEncryptionKey` (both
  `dependent: :destroy`).

### Access + encryption keys

- `StorageCredential` (`app/models/system/storage_credential.rb`) — a
  per-instance credential (NFS export grant handle, Samba user, STS token, …),
  sealed in Vault, with `issued → active → rotating → revoked` lifecycle and
  expiry/rotation predicates.
- `MountEncryptionKey` (`app/models/system/mount_encryption_key.rb`) — the
  at-rest key for `fscrypt`/`luks`/`client_side_aes` mounts; escrowed, material
  stored directly in Vault (never returned to the platform process).

### In-flight moves — `StorageMigration`

`app/models/system/storage_migration.rb` tracks moving a stateful component's
data (e.g. `/var/lib/postgresql`) from one `ProviderVolume` to another while
preserving the `(node_instance, role)` binding. It is distinct from
`System::Migration` (cross-peer record transfer). Its state machine is detailed
below.

---

## StorageMigration state machine

`StorageMigration` does **not** use AASM — it is a hand-rolled `TRANSITIONS`
hash validated by `transition_to!`. Statuses and rules below mirror the model
exactly.

```
STATUSES       = planned approved preparing syncing verifying cutover
                 completed failed cancelled
TERMINAL       = completed failed cancelled

  planned ──approve──▶ approved ──prepare──▶ preparing
     │                    │                      │
     │                    │                      ▼
     │                    │                   syncing
     │                    │                      │
     │                    │                      ▼
     │                    │                   verifying
     │                    │                      │
     │                    │                      ▼
     │                    │                   cutover
     │                    │                      │
     │                    │                      ▼
     └──cancel──┐ ┌─cancel─┘ ┌─cancel─┐      completed (terminal)
                ▼ ▼          ▼
              cancelled               failed (terminal; reachable
                                      from ANY non-terminal state)
```

**Forward transitions** (`TRANSITIONS` map, exact):

| From | Allowed next |
|------|--------------|
| `planned` | `approved`, `cancelled`, `failed` |
| `approved` | `preparing`, `cancelled`, `failed` |
| `preparing` | `syncing`, `cancelled`, `failed` |
| `syncing` | `verifying`, `failed` |
| `verifying` | `cutover`, `failed` |
| `cutover` | `completed`, `failed` |
| `completed` | — (terminal) |
| `failed` | — (terminal) |
| `cancelled` | — (terminal) |

**Rules:**

- **`failed`** is reachable from **every** non-terminal state (it appears in
  each non-terminal's allowed list, and `mark_failed!(reason:)` is a shortcut
  that records the reason + `failed_at` from any non-terminal state).
- **`cancelled`** is reachable **only** from `planned`, `approved`, or
  `preparing`. `cancel!(reason:, user:)` raises `ArgumentError` once the sync
  has started (status `syncing` or later) — cancellation is a pre-sync escape
  hatch only.

**Key methods** (all on `StorageMigration`):

- `transition_to!(new_status, message:, details:)` — validates the target is a
  known status and a legal transition, appends an audit entry, stamps the
  matching timestamp (`approved_at` / `started_at` on first `preparing` /
  `completed_at` / `failed_at` / `cancelled_at`), and on `→ completed` calls
  `promote_target_binding!`.
- `mark_failed!(reason:)` — no-op if already terminal; otherwise records the
  reason in `error_message` + `failed_at` and audit.
- `cancel!(reason:, user:)` — no-op if terminal; raises `ArgumentError` unless
  status ∈ `{planned, approved, preparing}`.
- `report_progress!(bytes_copied:, bytes_total:, bytes_verified:, note:)` —
  updates the byte counters and appends an audit note (the operator-visible
  timeline); does **not** change status on its own.
- `promote_target_binding!` — on `cutover → completed`, swaps the instance's
  `NodeInstance.config["storage_volume"]` binding from source to target so
  post-restart agent boots and heartbeat fetches mount the new home. It is
  defensively wrapped: on any error it logs a warning and appends a
  `promote_target_binding! warning: …` audit entry rather than raising — leaving
  a **silent half-cutover** (data at target, instance still bound to source)
  that the operator must reconcile. See the runbook's Failure modes.

The state advance happens **server-side** on operator/agent action; the actual
data copy (rsync) runs on the on-node Go agent, driven by the `agent_contract`
recipe in the migration `plan` (`steps: mount_target, snapshot, rsync, verify,
cutover, unmount_source`).

---

## The eight storage services

All live in `app/services/system/storage/`. Each one-paragraph summary is
grounded in the class's own top-of-file comment and public methods.

### `assignment_reconciliation_service.rb` — `AssignmentReconciliationService`

Drives a `StorageAssignment` toward its target state. Triggered by the
assignment's `after_commit`, by an agent heartbeat reporting a missing mount,
and by the periodic `StorageAssignmentDriftSensor`
(`app/services/system/fleet/sensors/storage_assignment_drift_sensor.rb`). Per
assignment it: dispatches an unmount task if a mounted assignment is now
disabled; honors an exponential backoff (`BACKOFF_BASE = 30s`, capped at
`30.minutes`) encoded in `error_message`; ensures an `Sdwan::Peer` exists
(auto-enrolling via `Sdwan::PeerEnroller`); ensures a non-expired
`StorageCredential` (issuing/rotating via `CredentialIssuer`); ensures a
`MountEncryptionKey` when the effective encryption mode is not `none`; and
finally creates a `storage.mount` `System::Task` with a payload from
`TaskPayloadBuilder`.

### `chown_dispatch_service.rb` — `ChownDispatchService`

Routes a pending chown for a `StorageAssignment` to the correct node's agent,
which runs `find -uid OLD -exec chown NEW {} +` and POSTs completion to
`/api/v1/system/worker_api/storage/chown_complete`
(`app/controllers/api/v1/system/worker_api/storage_chown_complete_controller.rb`).
Storage-type routing: `nfs`/`smb` chown runs on the **provider** node hosting the
export (gateway or backend); `ebs`/local-block/`fscrypt` run on the **consumer**
node (the assignment's `node_instance`); object stores (`s3`/`gcs`/`azure`) are a
no-op marked `complete` inline (object ACLs are metadata, not file ownership);
external/unmanaged NFS/SMB (no platform-managed provider node) is marked
`manual_required`. Idempotent — re-dispatch while `chown_state == "running"` is a
no-op. Dispatch failures flip the assignment to `chown_state = "failed"` and
raise `DispatchError`.

### `credential_issuer.rb` — `CredentialIssuer`

Issues, rotates, and revokes per-instance `StorageCredential`s. Flow: resolve
(or auto-enroll) the `Sdwan::Peer`; assemble a plain-hash context; call
`storage_provider.issue_node_credential` (pure data return); persist the
`StorageCredential` and seal the payload in Vault; then materialize the backend
side via `NfsExportManager#grant!` or `SmbUserManager#provision_user!` depending
on `provider_type`. `rotate!` issues a new credential then revokes the old;
`revoke!` tears down the backend grant/user and revokes the provider handle. A
scheme-crossing SMB rotation leaves the outgoing credential `rotating` until the
consumer confirms a remount; `rotating_since` records when that began, and
`RotatingCredentialSweeper` retires one that has waited past the operator's
window (`system.storage.smb_rotation_retire_window_hours`, default 24h) through
the same `CredentialIssuer` path, with an audit row and a fleet event naming the
node. It
deliberately re-fetches the credential via `Model.find(id)` (not `reload`) after
`store_in_vault` to dodge a known vault-credential cache reload bug.

### `gateway_provisioning_service.rb` — `GatewayProvisioningService`

Shape-2 (`gateway_proxy`) only. Configures a gateway powernode to mount an
external NFS/SMB server and **re-export** it on its SDWAN interface, so SDWAN
clients mount the gateway (the trust boundary) rather than the upstream.
`provision!` / `deprovision!` validate the storage is `gateway_proxy?` (raising
`ArgumentError` otherwise) and enqueue `storage.gateway.provision` /
`storage.gateway.deprovision` tasks to the gateway node. V1 ships plaintext
gateway↔upstream traffic (operator must place the gateway on a trusted subnet);
TLS wrapping is a V2 item.

### `mount_path_inference_service.rb` — `MountPathInferenceService`

Maps a `mount_path` to an inferred assignment **owner**. Used by the
owner-refactor backfill and by agent/operator surfaces wanting a sensible
default. A static, ordered `INFERENCE_RULES` table (more-specific patterns
first) maps well-known paths to owners — e.g. `/var/lib/postgresql →
service_user postgres`, `/var/www → www-data`, `/home/pnadmin → operator`,
`/var/log/audit → root`, `/tmp → nobody`. The rules live in code (not config)
because the mapping is a human-encoded convention that must stay auditable. By
design it fails **loud**: `infer(path)` returns `{ kind: :unresolved }` rather
than guessing a wrong owner, leaving the decision to the caller.
`resolvable?(path)` is the convenience predicate.

### `nfs_export_manager.rb` — `NfsExportManager`

Backend-side NFS export orchestrator. For Shape 1 (`self_hosted`) the backend
peer hosts the export directly; for Shape 2 (`gateway_proxy`) it is the gateway
re-exporting the upstream. `grant!` / `revoke!` enqueue `storage.exports.apply`
tasks for a single credential; `reconcile!` rewrites the whole exports file from
all enabled assignments (a rarely-invoked drift-recovery path). Per-storage
writes are serialized with a Postgres advisory lock
(`pg_advisory_xact_lock`, keyed on the storage UUID) so concurrent
`CredentialIssuer` runs can't race the `exports.d` file. Exports preserve
`effective_export_uid/gid` (the old owner during an in-flight chown).

### `smb_user_manager.rb` — `SmbUserManager`

Backend-side per-instance Samba user provisioner. `provision_user!` /
`deprovision_user!` / `rotate_user!` enqueue `storage.smb_user.apply` tasks
(actions `create` / `delete` / `set_password`) to the backend node — the storage
backend (Shape 1) or the gateway running Samba (Shape 2). Credentials
(`username`/`password`) come from the sealed `StorageCredential`'s
`vault_credentials`.

### `smb_rotation_preflight.rb` — `SmbRotationPreflight`

Read-only report an operator runs BEFORE rotating SMB credentials
(`rails system:storage:smb_rotation_preflight`, `FORMAT=json` for the structured
form). It writes nothing and dispatches nothing. Exit status: `0`
`safe_to_rotate`, `2` no SMB storage found, `1` anything else. An empty result
most likely means the wrong database, so the report names the Rails environment
and database it read and never treats "nothing found" as success.

Scope: fleet-wide across accounts, and every `provider_type: smb` storage is
scanned whatever its status and whether or not it holds a credential — a
credential issued between the preflight and the rotation lands on the same
backend agent. Each storage's status is printed.

For each instance a rotation would dispatch `storage.smb_user.apply` to, it
reports two checks as `pass` / `fail` / `unknown`:

- **agent** — whether the agent resolves the `CredentialRef` payload and keeps
  the value off `samba-tool`'s argv. Both commits landed on 2026-09-19. Decided
  from the heartbeated `agent_version`, which module builds stamp as
  `<UTC build date>-<12-hex sha>`: built before that date is a fail, on that
  date is unknown with no exception, after it is a pass with basis `build_date`.
  `build_date` is sound for a build from the default branch and not for a branch
  build; the report lists the shas seen with the command that settles one in an
  extension checkout, `git merge-base --is-ancestor 8f6aeae26de9 <sha>`.
- **accounts** — whether the instance serves SMB storages of exactly one
  account, its own.

SMB storages naming a backend instance that does not exist (fail) or none at
all (unknown) are listed separately. Unknown never counts as pass. Every result
that is not a pass carries a hint:

| Reason | What to do |
|---|---|
| `agent_version_not_orderable` | Redeploy a stamped module build; an unstamped agent (`dev`) cannot be ordered. |
| `stale_heartbeat` | No heartbeat in 3 minutes, so the recorded version may be out of date. Check the agent, then re-run. |
| `built_same_day_as_credential_ref_commit` | Settle it with the `git merge-base` command above, or redeploy a newer module build. |
| `predates_credential_ref` | Upgrade the agent; this one refuses the rotation payload. |
| `predates_payload_validation` | Upgrade the agent first; this one would run `samba-tool` with an empty value. |
| `serves_multiple_accounts` | Give each account's SMB storages a backend of its own. |
| `instance_account_differs_from_storage_account` | Correct the storage's backend. |
| `backend_instance_not_found` | Point the storage at a live backend or retire it. |
| `no_backend_instance_configured` | Confirm it is an external SMB server the platform provisions no users on. |

### `smb_bulk_rotation.rb` — `SmbBulkRotation`

Operator-run rotation of every live SMB credential (SMB remediation step 3),
because a password issued before extension commit c9eb9e72 may sit in a
historical task row. The loop ships the tooling; a person runs it. It reuses
`CredentialIssuer#rotate!` per credential, so the row lock, the successor
ordering and the deferred retirement of an old-scheme user until its consumer's
remount confirms all hold per item. Nothing in it reads or prints credential
material: rows carry ids, statuses and timestamps.

Runbook, in order (run from `server/` on the host that owns the target database):

1. `rails system:storage:smb_rotation_preflight` must exit `0` (`safe_to_rotate`).
   Resolve every `fail` and `unknown` first; the bulk task re-checks it at
   execute time and refuses anything else.
2. `rails system:storage:smb_rotate_all` is a **dry run** (the default). It names
   the environment and database, prints the preflight verdict, states
   `This will rotate N SMB credential(s)`, and shows the first 3 and the last 1.
   Confirm the database is the intended one and N is the number you expect.
3. `CONFIRM=N rails system:storage:smb_rotate_all` executes. `N` must equal the
   count the dry run printed; a different number refuses (exit `3`) and rotates
   nothing, so a fleet that changed since the dry run cannot be rotated on a
   stale confirmation. Credentials are rotated one at a time with a
   `[i/N]` progress line each.
4. It **stops at the first server-side failure** (exit `1`); the exception class is
   printed, never its message. Fix the cause, then
   resume with `SINCE=<the started_at it printed before item 1> CONFIRM=<new dry-run count>
   rails system:storage:smb_rotate_all`; `SINCE` skips credentials already
   rotated at or after that time.
5. `rails system:storage:smb_rotate_verify` (read-only, re-runnable) until it
   exits `0` (`COMPLETE`). Rotation dispatches work and does not wait for agents.
   The remount is dispatched when the agent completes the rotation task, and a
   mounted consumer that has not confirmed is re-dispatched by the drift sweep
   (`StorageAssignment.mount_credential_mismatch`). Verify reports each consumer
   as `confirmed` (the agent confirmed `mounted_credential_id` equals the active
   credential) or `stale_mount` (still on the superseded credential), counts
   credentials still `rotating`, and lists excluded assignments (below).

Pilot first: the stop-at-first-failure only sees server-side failures (vault,
database, no backend configured), because rotation merely enqueues tasks; a
broken agent shows up later, in verify. So run `LIMIT=1` (the dry run says
`limit=1 of N eligible`; `CONFIRM` then restates 1), run verify until that one
consumer is `confirmed`, and only then run the rest.

Excluded, never rotated by this tool: assignments that are disabled, are not
`mounted`/`degraded`, or have no confirmed mount (`mounted_credential_id` NULL).
RemountCoordinator and the drift sweep cannot remount a consumer with no
confirmed mount, so rotating it would lock the consumer out once the sweeper
retires the old user. The dry run and verify list each with its reason; an
operator handles them separately (a disabled assignment is also not in verify's
`COMPLETE` check).

What it does not cover: it does not wait for or retry agents, it does not roll a
rotation back, and an assignment with no active credential is not in the plan
(it has nothing to rotate). Re-running without `SINCE` after a complete run
rotates everything again; `SINCE` must carry a zone and must not be in the future. Every rotation of an old-scheme credential changes
the samba username (a new per-assignment user is created and the old shared user
is deleted once no sibling uses it), so the consumer's remount, not the
rotation, is what makes it work again.

#### Historical rows: the `storage.smb_user.apply` secret scrub

Before extension commit c9eb9e72 the task payload carried the SMB password in
plaintext (`options.password`, plus `options.new_password` on `set_password`),
and a failed run echoed it through the agent's argv error into `error_message`
and the mirrored `failed` event in `events`. The data migration
`20261001120000_scrub_smb_user_apply_task_secrets` rewrites those rows at boot:
the two option keys keep their names with the value `[REDACTED]`, the row's own
value is replaced wherever it appears in `error_message`, `description` and
`events[].message`, and the argv shape (`samba-tool [user create <user> …]: `,
`samba-tool [user setpassword <user> --newpassword=…]: `) is redacted by
pattern for rows whose options no longer hold the value — argv only, so on
such a row a repeat of the value in the output tail survives. The value arm is
deliberately not gated on the password's length: a very short password that is
also a substring of ordinary message text over-redacts that text, never
under-redacts. Scope is the one command, exactly; other tasks are untouched.
The rewrite is raw SQL, so `updated_at` is not bumped and no callback, audit
hook or broadcast fires. It is batched, idempotent, skips rows some concurrent
transaction holds a row lock on (a running task holds none between its status
writes), bounds the one wait it cannot skip (a table-level lock) with a 5s
`lock_timeout`, never raises on a row of an unexpected shape (it reports such
rows by count), and prints counts only. A rescued error or a locked row leaves
the migration stamped with rows behind, and the boot log says so with the
leftover count. `down` is a no-op.

**Re-running the scrub.** Never through `db:migrate`: a production control
plane declares several databases, so Rails refuses the un-suffixed
`db:migrate:up/down/redo` there, and the suffixed form does not exist on
single-database dev/test. Use the rake task, which loads the migration file and
runs the same scrub, prints the same count lines plus the leftover count, and
exits 0 when nothing is left, 2 when candidate rows remain, 1 when the scrub
aborted; it never touches `schema_migrations`:

```
rails system:storage:scrub_smb_task_secrets
```

On a module-composed node run it through the node's rails exec wrapper
(`powernode-rails-exec rake system:storage:scrub_smb_task_secrets`), not a bare
`bundle exec`, which resolves a different extension set and rewrites the
service's lockfile.

**What the scrub does not reach.** The migration removes the copy in the live
`system_tasks` heap. It does not reach:

- **the second copy in the database.** A `storage.smb_user.apply` task created
  through the REST door passed the core autonomy gate, which stores the task
  attributes — options included, unfiltered — in
  `ai_deferred_operations.params` at the JSON path
  `{task_attributes,options}` (`action_category =
  'system.task.storage.smb_user.apply'`). That is a core table and widening
  the scrub to it is an operator decision filed separately. To see whether
  this deployment holds any such row:

  ```sql
  SELECT count(*) FROM ai_deferred_operations
  WHERE action_category = 'system.task.storage.smb_user.apply'
    AND jsonb_typeof(params #> '{task_attributes,options}') = 'object'
    AND params #> '{task_attributes,options}' ?| ARRAY['password', 'new_password'];
  ```
- dead tuples of the rewritten rows until `VACUUM` reclaims them (the migration
  deliberately does not `VACUUM FULL`);
- the WAL that carried the original writes, WAL archives and any PITR base
  backup taken while the rows held the value;
- `pg_dump` files, snapshot-based backups and a replica's own backups (the
  rewrite itself replicates, the replica's past backups do not change);
- the `events[].data` sub-object, which the writers leave empty and the scrub
  does not rewrite, and a password containing `]` on a row whose options were
  already stripped: the argv pattern does not match such an echo at all, so the
  whole value stays and the row is not counted in the "not scrubbed" line (the
  value arm removes it whenever the option value is still there);
- logs: the agent's journal and the platform's request logs on the node API
  `fail` endpoint, where `error_message` is not a filtered parameter name;
- copies made by anything that read the task row while it held the value
  (`system_get_task` results stored in conversations or agent executions);
- the `/proc/<pid>/cmdline` exposure on the backend host while the pre-fix
  agent ran `samba-tool`, which c9eb9e72 recorded separately.

Credential rotation is the actual remedy: a password that has been rotated is
worthless in every copy above. Run the preflight first, rotate, and only then
treat the scrub as having closed the historical copy.

### `task_payload_builder.rb` — `TaskPayloadBuilder`

Composes the JSON task payloads the on-node agent receives via `System::Task`.
Builds `mount` / `unmount` / `exports.apply` / `gateway.provision` /
`gateway.deprovision` payloads. Mount recipes come from the provider layer's
`FileManagement::Storage#node_mount_recipe(context:)` (pure data — no extension
types leak into the platform provider layer); the builder layers on combined
mount options, the read-only flag, an encryption payload, the systemd unit name
(`powernode-storage-<sanitized-path>.mount`), and the WireGuard interface hint.
Object-storage recipes (`s3fs`/`gcsfuse`/`rclone`) skip the WireGuard
requirement (native egress); everything else rides SDWAN.

---

## Chown dispatch + reconciliation flow

An ownership change on a `StorageAssignment` (via `system_assign_storage_owner`)
commits, then `StorageAssignment#dispatch_chown_if_pending` calls
`ChownDispatchService.dispatch!`. The service records `chown_previous_uid/gid`,
flips `chown_state → running`, and enqueues a `storage.chown` task to the node
that actually owns the files (provider node for NFS/SMB; consumer node for
block/fscrypt). While `chown_state` is in-flight, `effective_export_uid/gid`
returns the **previous** owner, so the NFS export (rewritten by
`NfsExportManager`/`TaskPayloadBuilder`) keeps serving the old IDs and avoids an
`EACCES` storm. The agent runs the recursive `chown` and POSTs to the
`storage_chown_complete` worker endpoint, which flips `chown_state → complete`
and clears the previous IDs. Failures land in `chown_state = failed` (or
`manual_required` for unreachable/external providers) and are surfaced + retried
via `system_storage_chown_status` / `system_storage_chown_retry`.

Separately, `AssignmentReconciliationService` is the mount-level reconciler: it
re-mounts drifted/failed assignments, issues/rotates credentials, and unmounts
disabled ones, with exponential backoff on repeated failure.

---

## NFS / SMB exports, credentials, gateways, mount-path inference

These cooperate to bring a network mount up:

1. `MountPathInferenceService` proposes the owner for a new mount (or the
   backfill resolves it).
2. `CredentialIssuer` mints the per-instance `StorageCredential` (Vault-sealed)
   and calls the backend materializer.
3. `NfsExportManager` (NFS) or `SmbUserManager` (SMB) writes the backend-side
   export entry / Samba user via a node task.
4. For external upstreams behind a gateway, `GatewayProvisioningService` mounts
   the upstream on the gateway and re-exports it on the SDWAN interface.
5. `TaskPayloadBuilder` builds the consumer-side `storage.mount` payload (recipe
   + options + encryption + WireGuard hint) and `AssignmentReconciliationService`
   dispatches it.

Reachability of an NFS upstream can be probed **before** recording a volume with
`system_test_nfs_export` (DNS + TCP 111/2049 + `showmount -e`; it never mounts).

---

## MCP tool surface

All actions below are registered in the parent platform's tool registry and
dispatched by `app/services/ai/tools/system_fleet_tool.rb` (volumes + migrations
+ recommendations + NFS probe) and
`app/services/ai/tools/system_storage_owner_tool.rb` (ownership + chown).

### Volume lifecycle

| Action | Purpose | Key params |
|--------|---------|------------|
| `system_list_volumes` | List ProviderVolumes | `status`, `transport`, `node_instance_id`, `unattached_only` |
| `system_get_volume` | Full detail on one volume | `volume_id` |
| `system_create_volume` | Register a ProviderVolume | `name`, `size_gb`, `transport`, `nfs_server`, `nfs_export_path`, … |
| `system_update_volume` | Update name/desc/size/status | `volume_id`, … |
| `system_delete_volume` | Delete a volume (must be detached) | `volume_id` |
| `system_attach_volume` | Attach to a NodeInstance | `volume_id`, `node_instance_id`, `role` |
| `system_detach_volume` | Detach from a NodeInstance | `volume_id`, `node_instance_id` |
| `system_test_nfs_export` | Probe an NFS server/export (no mount) | `server`, `export_path` |

### Snapshots + restore (data protection)

Added by APO-5 / DR-2. Before it, the platform's only backup was its **own**
database (the worker's `Maintenance::ScheduledBackupJob`); a project's volumes
had no snapshot and no restore at any surface, so the DR story was
re-provision-only. `POST /provider_volumes/:id/snapshot` existed but never
reached a provider — it inserted a `pending` row and returned 201, so the row
an operator read as a restore point was evidence of nothing.

Everything below runs through `System::VolumeManagementService`, which keeps
one rule: **the snapshot row never claims more than the provider did.** A
provider with no snapshot primitive leaves *no* row; a provider whose call
fails leaves an `error` row; only a provider that reports success yields
`completed`, and only `completed` is a restore point (`#can_restore?`).

Provider support is declared by `System::Providers::BaseProvider
#supports_volume_snapshots?` (default **false**). **Azure** implements the seam
over `Microsoft.Compute/snapshots`. **Proxmox reports false**: PVE snapshots are
VM-scoped, so a "volume" rollback would take every disk on the VM (and its RAM
state) with it — an instance-level verb, not this one.

| Action | Purpose | Key params |
|--------|---------|------------|
| `system_snapshot_volume` | Snapshot a volume via its provider | `volume_id`, `name`, `description` |
| `system_list_volume_snapshots` | List a volume's snapshots, newest first | `volume_id` |
| `system_delete_volume_snapshot` | **DESTROYS a restore point** — approval-gated; provider delete then row drop | `snapshot_id` |
| `system_restore_volume_snapshot` | Restore a volume from a completed snapshot — read `restored_in_place` | `snapshot_id`, `swap_into_place` |

**Restore is not one thing**, and every surface reports which it got.
`BaseProvider#volume_snapshot_restore_mode` declares it:

- `:in_place` — the volume itself is rolled back. **DESTRUCTIVE**: every write
  since the snapshot is discarded.
- `:copy` — the provider creates a **new** volume from the snapshot and leaves
  the source untouched. This is **Azure's** shape (`createOption: "Copy"`), so
  it is what the one supporting provider actually does. The service records the
  copy as a `ProviderVolume` row and returns it as `restored_volume`; without
  that row the restored disk would be unattachable and undeletable through the
  platform — an untracked, billable orphan — while the surfaces above reported
  the source volume as restored.
- `:none` (the default) — no restore primitive; `restore_snapshot` refuses.

REST twins: `POST /provider_volumes/:id/snapshot`, `GET
/provider_volumes/:id/snapshots`, `POST /provider_volumes/:id/restore`
(`snapshot_id`). The skill surface is
`System::Ai::Skills::RestoreVolumeExecutor` (`system-restore-volume`), which is
`requires_approval: true`, declares **no** rollback (a restore has no inverse)
and takes a pre-restore snapshot first by default.

Snapshot **delete** is approval-gated (IMP-e025722ef14e): the MCP verb
declares the full gate quartet on `Ai::Executors::DeferredToolCall` under
`system.volume_snapshot_delete`, declared in
`System::Governance::PolicyDeclarations::VOLUME_SNAPSHOT_OPERATOR_POLICIES`
(operator scope, `require_approval`; the row itself is written by the
governance reconciler — on every boot, the first one included, and via
`rake system:governance:reconcile` — from the `volume-snapshot-operator`
`POLICY_SETS` entry, since the Autonomy modal's pivot is row-driven and a
declaration alone shows nothing). A pending response means nothing was deleted; on
approval the same action body is replayed as the original principal. Create,
list and restore keep the APO-1a `mutating:`-only shape.

A **copy restore can be swapped into place**: `swap_into_place: true` (on the
MCP verb, the skill executor and `VolumeManagementService.restore_snapshot`)
detaches the source from its instance and attaches the recorded copy at the
same device, reporting `swapped: true`. It is opt-in because it detaches a
live disk; by default both volumes are left where they are. A swap that fails
midway is reported as a failure naming the stage (`swap_stage: "detach"` — the
source is still attached — or `"attach"` — the source is now detached and the
copy unattached), with the copy still named so it cannot become an untracked
orphan. It is skipped, and says so (`swap_skipped`), on an in-place restore or
when the source was not attached.

A project's **snapshot schedule** is declared on its mission
(`watch_policies.snapshot_interval_hours` / `snapshot_retention_count`,
resolved through the same template → account → `SiteSetting`
`ai.provisioning.snapshot_*` ladder as the scaling window, both defaulting to
0 = off) and evaluated by `VolumeManagementService.snapshot_schedule_for`,
which names the volumes DUE a snapshot and the completed snapshots beyond
retention that are PRUNABLE. **No fleet sensor emits from it yet** — until one
is registered in `FleetAutonomyService::SENSORS` (with pruning routed through
the same `system.volume_snapshot_delete` gate as the verb), a declared
schedule is evaluated only by whoever calls the service, so setting
`snapshot_interval_hours` on a project does **not** yet cause snapshots to be
taken. That sensor is tracked as improvement
`01a065df-4ab7-7a04-8293-8069d805b0b1`.

### Migration lifecycle

| Action | Purpose | Key params |
|--------|---------|------------|
| `system_migrate_storage_component` | Create a `planned` StorageMigration + plan | `node_instance_id`, `source_volume_id`, `target_volume_id`, `role` |
| `system_list_storage_migrations` | List migrations (newest, cap 100) | `status`, `node_instance_id`, `active_only` |
| `system_get_storage_migration` | Fetch one (plan, bytes, audit log) | `migration_id` |
| `system_approve_storage_migration` | `planned → approved` | `migration_id` |
| `system_cancel_storage_migration` | Cancel pre-sync only | `migration_id`, `reason` |
| `system_report_storage_migration_progress` | Advance phase + record bytes | `migration_id`, `status`, `bytes_copied`, `bytes_total`, `bytes_verified`, `note` |
| `system_revert_storage_migration_binding` | (Increment 9) Request the agent re-point the mount back to source | `migration_id`, `reason` |
| `system_cleanup_storage_migration` | (Increment 9) **DESTRUCTIVE** — delete target-side scratch artifacts only | `migration_id`, `reason`, `immediate` |

### Ownership + chown

| Action | Purpose | Key params |
|--------|---------|------------|
| `system_assign_storage_owner` | Set assignment owner (triggers chown) | `storage_assignment_id`, `owner_kind`, `service_user_username`, `shared_group_groupname` |
| `system_list_storage_assignments_by_owner` | Audit ownership/chown across the fleet | `owner_kind`, `service_user_username`, `node_instance_id`, `chown_state` |
| `system_storage_chown_status` | Inspect chown state of one assignment | `storage_assignment_id` |
| `system_storage_chown_retry` | Re-dispatch a failed/manual chown | `storage_assignment_id`, `force_complete` |

### Recommendations

| Action | Purpose | Key params |
|--------|---------|------------|
| `system_get_storage_recommendations` | Read role mount points + sizes | — |
| `system_update_storage_recommendations` | Partial-merge override | `recommendations` |

Permissions: ownership/chown actions gate on `system.storage.read` and
`system.storage.assignments.update`; volume actions on `system.volumes.*`
(snapshot create on `system.volumes.snapshot`, snapshot delete on
`system.volumes.delete`, restore on `system.volumes.manage`);
migration + recommendations on `system.platform.read` / `system.platform.scale`.
For the curated MCP reference see [MCP_API_REFERENCE.md](./MCP_API_REFERENCE.md).

---

## Dangerous operations

Four storage operations change or destroy data-bearing state and warrant
operator care. The end-to-end procedure + per-failure remediation lives in
[runbooks/storage-migration.md](./runbooks/storage-migration.md).

| Operation | Why it's dangerous | Guardrail |
|-----------|--------------------|-----------|
| **Migration cutover** (`cutover → completed`) | Swaps the instance's `storage_volume` binding source→target; a failure in `promote_target_binding!` leaves a silent half-cutover (data at target, instance bound to source) | Defensive rescue + audit warning (`metadata.promote_failed`); `system_revert_storage_migration_binding` reconciles it (increment 9) |
| **`system_cleanup_storage_migration`** (increment 9) | Deletes the migration's target-side data — the `target_subpath` partial copy + `snapshot_subpath` scratch | **Subpath-scoped only** — never the source, never the volume itself (the target volume is never attached during a migration, so a volume-level delete could reach other deployments' data on shared NFS); explicit operator action only, never auto-run on failure; gated by a grace window (`system.storage.migration.cleanup_grace_hours`, default 24h, `immediate: true` to override); reachable only from `failed`/`cancelled` (post-preparing); idempotent (missing artifact = already clean); one audit entry per artifact naming the exact path |
| **chown** (`system_assign_storage_owner`) | Recursive `chown` over an entire mount; wrong owner makes a service unable to read its own data | Loud `:unresolved` inference, `effective_export_uid/gid` masks the change until complete, `failed`/`manual_required` states + retry |
| **`system_delete_volume`** | Removes backing storage | Refuses while the volume is attached (`can_delete?` = `available`/`error` **and** unattached) |

---

## Related code + docs

- Models: `app/models/system/{provider_volume,provider_volume_type,provider_volume_member,storage_assignment,storage_credential,mount_encryption_key,storage_migration}.rb`
- Services: `app/services/system/storage/` (the eight above) +
  `app/services/system/platform/{storage_recommendations,storage_layout}.rb`
- Sensor: `app/services/system/fleet/sensors/storage_assignment_drift_sensor.rb`
- MCP tools: `app/services/ai/tools/{system_fleet_tool,system_storage_owner_tool}.rb`
- Controllers: `app/controllers/api/v1/system/{provider_volumes_controller,storage_assignments_controller,storage_credentials_controller}.rb`,
  `app/controllers/api/v1/system/platform/{volumes_controller,storage_migrations_controller}.rb`,
  `app/controllers/api/v1/system/node_api/{storage_volume_controller,storage_assignments_controller,storage_migrations_controller}.rb`,
  `app/controllers/api/v1/system/worker_api/{volumes_controller,storage_chown_complete_controller}.rb`
- Runbook: [runbooks/storage-migration.md](./runbooks/storage-migration.md)
- Substrate overview: [ARCHITECTURE.md](./ARCHITECTURE.md) · sensor reference:
  [FLEET_SENSORS.md](./FLEET_SENSORS.md)

---

_Last verified: 2026-06-26_
</content>
</invoke>
