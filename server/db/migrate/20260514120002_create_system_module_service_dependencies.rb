# frozen_string_literal: true

# P1.2 — system_module_service_dependencies: directed edges between
# ModuleServices in the same module. Lets a module declare "the worker waits
# for rails to be healthy" or "postgres starts before rails" without baking
# the order into manifest_yaml's start sequence.
#
# kind semantics:
#   - start_before:    target must start (PID alive) before source starts
#   - requires_health: target must pass its health check before source starts
#   - softdep:         target is preferred-running but not required (best-effort)
class CreateSystemModuleServiceDependencies < ActiveRecord::Migration[8.0]
  def change
    create_table :system_module_service_dependencies, id: :uuid do |t|
      t.references :module_service,
        type: :uuid, null: false,
        foreign_key: { to_table: :system_module_services, on_delete: :cascade },
        index: false  # superseded by compound unique below
      t.references :depends_on_module_service,
        type: :uuid, null: false,
        foreign_key: { to_table: :system_module_services, on_delete: :cascade }

      t.string :kind, null: false, default: "requires_health", limit: 32

      t.timestamps
    end

    add_index :system_module_service_dependencies,
      %i[module_service_id depends_on_module_service_id],
      unique: true,
      name: "idx_msd_unique_edge"

    # Self-reference prevented in model validation; DB-level CHECK is overkill
    # for a 4-column table that won't see direct SQL writes.
  end
end
