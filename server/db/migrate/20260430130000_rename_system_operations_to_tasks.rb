# frozen_string_literal: true

# Rename System::Operation → System::Task to align with the platform's
# "worker performs Tasks" terminology. The cloud-shaped term "Operation"
# was inherited from the legacy powernode-server schema; "Task" matches
# how the rest of the platform talks about background work-units (see
# AI::TaskExecution, etc.).
#
# This migration:
#   - Renames the system_operations table to system_tasks
#   - Renames the unique idempotency index to match
#   - Updates seeded permission rows from system.operations.* to
#     system.tasks.* (worker-API permissions) and system.infra_operations.*
#     to system.infra_tasks.* (operator-facing permissions)
#
# Foreign-key columns referencing this table (claimed_by_worker_id,
# operable_*, account_id, initiated_by_id) keep their names since they
# point AT this table; no other table references it via a FK column
# named "operation_id" yet.
class RenameSystemOperationsToTasks < ActiveRecord::Migration[8.1]
  PERMISSION_RENAMES = {
    "system.operations.read"          => "system.tasks.read",
    "system.operations.create"        => "system.tasks.create",
    "system.operations.manage"        => "system.tasks.manage",
    "system.operations.execute"       => "system.tasks.execute",
    "system.infra_operations.read"    => "system.infra_tasks.read",
    "system.infra_operations.create"  => "system.infra_tasks.create",
    "system.infra_operations.control" => "system.infra_tasks.control"
  }.freeze

  RESOURCE_RENAMES = {
    "system.operations"       => "system.tasks",
    "system.infra_operations" => "system.infra_tasks"
  }.freeze

  def up
    rename_table :system_operations, :system_tasks
    rename_index :system_tasks, "idx_system_operations_idempotency", "idx_system_tasks_idempotency"
    rename_permissions(PERMISSION_RENAMES, RESOURCE_RENAMES)
  end

  def down
    rename_table :system_tasks, :system_operations
    rename_index :system_operations, "idx_system_tasks_idempotency", "idx_system_operations_idempotency"
    rename_permissions(PERMISSION_RENAMES.invert, RESOURCE_RENAMES.invert)
  end

  private

  def rename_permissions(name_map, resource_map)
    name_map.each do |old_name, new_name|
      execute "UPDATE permissions SET name = '#{new_name}' WHERE name = '#{old_name}'"
    end
    resource_map.each do |old_resource, new_resource|
      execute "UPDATE permissions SET resource = '#{new_resource}' WHERE resource = '#{old_resource}'"
    end
  end
end
