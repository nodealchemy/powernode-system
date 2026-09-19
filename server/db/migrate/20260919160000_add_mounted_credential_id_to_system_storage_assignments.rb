# frozen_string_literal: true

# IMP-e48612a32273 — the confirmation record for what a consumer is ACTUALLY
# mounted with, distinct from StorageAssignment#active_credential (the DB's
# notion of "should be mounted with"). Set only when a storage.mount task for
# this assignment reports COMPLETE, to the credential id that task named —
# see System::Storage::RemountCoordinator. Load-bearing for three things:
#   - drift detection: a "mounted" assignment whose mounted_credential_id no
#     longer matches its current active_credential (see the new
#     mount_credential_mismatch scope) is picked back up by reconcile even
#     though nothing on the assignment record itself changed;
#   - the remount decision: AssignmentReconciliationService#dispatch_mount!
#     asks for a systemctl restart (not a no-op start) whenever this differs
#     from the credential it is about to dispatch;
#   - the retire-old-user ordering gate: the old samba user is not deleted
#     until THIS column flips to the new credential's id, confirming the
#     consumer's own remount actually landed.
#
# Nullable: unset for every pre-existing row and for an assignment that has
# never completed a mount yet. on_delete: :nullify (not :cascade / restrict)
# matches this table's other optional, informational references
# (sdwan_network_id, sdwan_virtual_ip_id) — this column records a FACT about
# a past mount, not a live dependency the credential's own destroy path
# should be blocked by or need to know about.
class AddMountedCredentialIdToSystemStorageAssignments < ActiveRecord::Migration[8.1]
  # up/down instead of change (review BLOCKER 1): a plain `change` with
  # add_reference alone would leave every PRE-EXISTING row NULL, and
  # StorageAssignment.mount_credential_mismatch reads `mounted_credential_id
  # IS DISTINCT FROM <active credential>` — NULL IS DISTINCT FROM any
  # non-null value is TRUE, so on the very first drift tick after deploy
  # EVERY already-mounted SMB share in the fleet would match the scope and
  # get `systemctl restart`ed at once. The backfill below sets
  # mounted_credential_id to whatever StorageAssignment#active_credential
  # (see that method's own SQL — mirrored here) already resolves, for every
  # row currently mounted or degraded, so a real fleet's already-working
  # mounts read as "confirmed", not "mismatched", the moment this ships.
  # Guarded by column_exists? so `up` is safe to call a second time
  # (spec/db/migrate/add_mounted_credential_id_to_system_storage_
  # assignments_spec.rb calls it directly against the already-migrated
  # schema to test the backfill SQL in isolation).
  def up
    unless column_exists?(:system_storage_assignments, :mounted_credential_id)
      add_reference :system_storage_assignments, :mounted_credential,
                    type: :uuid, index: true,
                    foreign_key: { to_table: :system_storage_credentials, on_delete: :nullify }
    end

    execute(<<~SQL.squish)
      UPDATE system_storage_assignments a
      SET mounted_credential_id = (
        SELECT c.id FROM system_storage_credentials c
        WHERE c.storage_assignment_id = a.id
        AND c.status IN ('issued', 'active')
        ORDER BY c.created_at DESC
        LIMIT 1
      )
      WHERE a.status IN ('mounted', 'degraded')
    SQL
  end

  # Anything the backfill couldn't resolve (no live issued/active
  # credential row for a mounted/degraded assignment — shouldn't happen,
  # but the UPDATE's subquery returns NULL rather than erroring if it does)
  # stays NULL exactly as a never-mounted assignment already would — belt-
  # and-braces, .mount_credential_mismatch itself also excludes NULL (see
  # that scope's own comment) so an unresolved row is never swept as a
  # false "mismatch" either.
  def down
    remove_reference :system_storage_assignments, :mounted_credential,
                      foreign_key: { to_table: :system_storage_credentials }
  end
end
