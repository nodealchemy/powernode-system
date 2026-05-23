# frozen_string_literal: true

# Replaces the per-instance hashed `derived_uid` on StorageAssignment
# with a platform-allocated ServiceUser-based ownership model.
#
# Before this migration:
#   anonuid = 100_000 + (hash(node_instance_id) % 100_000)
#   — same UID for ALL services on a node, different UID per node,
#     fragile under cross-node migrations and shared-storage scenarios.
#
# After this migration:
#   owner_kind enum (service_user | operator | nobody | root) + optional
#   service_user_id + optional shared_group_id. The `anonuid` method
#   dispatches on owner_kind. Chown lifecycle columns (chown_state,
#   chown_previous_uid/gid, etc.) track in-flight ownership changes so
#   the on-node agent can re-chown files when an operator changes the
#   owner via the new system_assign_storage_owner MCP tool.
#
# Backfill strategy (per locked "clean break" decision):
#   - Each existing assignment's mount_path runs through
#     MountPathInferenceService. Matched rows get owner_kind +
#     service_user_id auto-populated.
#   - Unmatchable rows abort the migration with a helpful list. The
#     operator deletes the orphan StorageAssignment OR assigns it
#     manually via the system_assign_storage_owner MCP tool, then
#     re-runs the migration.
#
# Plan reference: ~/.claude/plans/storage-assignment-owner-refactor.md
class RefactorStorageAssignmentOwner < ActiveRecord::Migration[8.1]
  OWNER_KINDS  = %w[service_user operator nobody root].freeze
  CHOWN_STATES = %w[complete pending running failed manual_required].freeze

  def up
    # 1. Owner columns (nullable for backfill).
    add_column :system_storage_assignments, :owner_kind, :string,
               null: true, limit: 32, default: "service_user"
    add_reference :system_storage_assignments, :service_user,
                  type: :uuid, foreign_key: { to_table: :system_service_users },
                  null: true, index: true
    add_reference :system_storage_assignments, :shared_group,
                  type: :uuid, foreign_key: { to_table: :system_service_groups },
                  null: true, index: true

    # 2. Chown lifecycle columns. Track in-flight ownership changes so
    #    the agent's chown task can resume after retries / failures and
    #    operators can observe progress via MCP.
    add_column :system_storage_assignments, :chown_state, :string,
               null: false, limit: 32, default: "complete"
    add_column :system_storage_assignments, :chown_previous_uid, :integer, null: true
    add_column :system_storage_assignments, :chown_previous_gid, :integer, null: true
    add_column :system_storage_assignments, :chown_started_at, :datetime, null: true
    add_column :system_storage_assignments, :chown_completed_at, :datetime, null: true
    add_column :system_storage_assignments, :chown_last_error, :text, null: true
    add_column :system_storage_assignments, :chown_task_id, :uuid, null: true
    add_index  :system_storage_assignments, :chown_state,
               where: "chown_state != 'complete'",
               name:  "index_system_storage_assignments_chown_in_flight"

    # 3. Backfill owners via mount_path inference. No chown — fresh
    #    instances get correct ownership from day one per the locked
    #    clean-break decision; ongoing operator-driven owner changes
    #    will trigger chown via the after_commit hook on the model.
    backfill_owners!

    # 4. Tighten constraints. owner_kind is now required; service_user_id
    #    is required iff owner_kind = 'service_user' (and forbidden
    #    otherwise — keeps the model invariant explicit at the DB layer).
    change_column_null :system_storage_assignments, :owner_kind, false
    add_check_constraint :system_storage_assignments,
                         "owner_kind IN ('service_user','operator','nobody','root')",
                         name: "system_storage_assignments_owner_kind_enum"
    add_check_constraint :system_storage_assignments,
                         "(owner_kind = 'service_user' AND service_user_id IS NOT NULL) OR " \
                         "(owner_kind != 'service_user' AND service_user_id IS NULL)",
                         name: "system_storage_assignments_owner_kind_consistency"
    add_check_constraint :system_storage_assignments,
                         "chown_state IN ('complete','pending','running','failed','manual_required')",
                         name: "system_storage_assignments_chown_state_enum"

    # 5. Drop the legacy hash-based UID column. Defensive guard for the
    #    case where the column has already been dropped by a prior
    #    failed run + manual remediation.
    remove_column :system_storage_assignments, :derived_uid if column_exists?(:system_storage_assignments, :derived_uid)
  end

  def down
    add_column :system_storage_assignments, :derived_uid, :integer
    remove_check_constraint :system_storage_assignments, name: "system_storage_assignments_chown_state_enum"
    remove_check_constraint :system_storage_assignments, name: "system_storage_assignments_owner_kind_consistency"
    remove_check_constraint :system_storage_assignments, name: "system_storage_assignments_owner_kind_enum"
    remove_index :system_storage_assignments, name: "index_system_storage_assignments_chown_in_flight"
    %i[chown_task_id chown_last_error chown_completed_at chown_started_at
       chown_previous_gid chown_previous_uid chown_state].each do |col|
      remove_column :system_storage_assignments, col
    end
    remove_reference :system_storage_assignments, :shared_group
    remove_reference :system_storage_assignments, :service_user
    remove_column :system_storage_assignments, :owner_kind
  end

  private

  # Walks every existing StorageAssignment row and uses the inference
  # service to choose an owner. Failures are collected and reported via
  # IrreversibleMigration — the operator must clear them (via the new
  # MCP tool or by deleting orphan rows) before re-running.
  def backfill_owners!
    say_with_time "Backfilling system_storage_assignments owner_kind / service_user_id" do
      ::System::StorageAssignment.reset_column_information
      unresolved = []

      ::System::StorageAssignment.find_each do |assignment|
        inference = ::System::Storage::MountPathInferenceService.infer(assignment.mount_path)
        case inference[:kind]
        when :service_user
          user = ::System::Identity::UserAllocator.allocate!(username: inference[:username])
          assignment.update_columns(owner_kind: "service_user", service_user_id: user.id)
        when :operator, :nobody, :root
          assignment.update_columns(owner_kind: inference[:kind].to_s, service_user_id: nil)
        else
          unresolved << {
            id:                assignment.id,
            mount_path:        assignment.mount_path,
            node_instance_id:  assignment.node_instance_id
          }
        end
      end

      next if unresolved.empty?

      preview = unresolved.first(20).map { |u| "  - #{u[:id]} mount_path=#{u[:mount_path]} instance=#{u[:node_instance_id]}" }
      tail    = unresolved.size > 20 ? "\n  ... and #{unresolved.size - 20} more" : ""
      raise ActiveRecord::IrreversibleMigration, <<~MSG
        #{unresolved.size} storage assignment(s) could not be auto-resolved by mount_path inference.
        Two recovery paths:
          (a) Assign via MCP: system_assign_storage_owner(storage_assignment_id, owner_kind, ...)
          (b) Delete the orphan row if it's no longer needed.
        Then re-run `rails db:migrate`.

        Unresolved assignments:
        #{preview.join("\n")}#{tail}
      MSG
    end
  end
end
