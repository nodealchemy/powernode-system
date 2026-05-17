# frozen_string_literal: true

# P5.2 — system_migration_plan_steps: ordered list of per-record actions
# composing one Migration. The PlanComposer walks the dependency graph
# from the Migration's root and produces one step per record encountered.
#
# Plan reference: Decentralized Federation §F + P5.2.
class CreateSystemMigrationPlanSteps < ActiveRecord::Migration[8.0]
  def change
    create_table :system_migration_plan_steps, id: :uuid do |t|
      t.references :migration,
        type: :uuid, null: false,
        foreign_key: { to_table: :system_migrations, on_delete: :cascade }

      t.integer :step_order, null: false

      t.string :resource_kind, null: false, limit: 64
      t.uuid   :resource_id,   null: false

      t.string :action,          null: false, limit: 24
      t.string :conflict_policy, null: false, default: "fail", limit: 32

      t.jsonb :payload,  null: false, default: {}
      t.jsonb :metadata, null: false, default: {}

      t.datetime :applied_at
      t.string   :error_message, limit: 2048

      t.timestamps
    end

    add_index :system_migration_plan_steps, %i[migration_id step_order],
      unique: true, name: "idx_migration_plan_steps_order_unique"
    add_index :system_migration_plan_steps, %i[resource_kind resource_id]
    add_index :system_migration_plan_steps, :action

    add_check_constraint :system_migration_plan_steps,
      "action IN ('create', 'link_local', 'skip', 'conflict')",
      name: "migration_plan_steps_action_enum"

    add_check_constraint :system_migration_plan_steps,
      "conflict_policy IN ('skip_if_exists', 'rename_with_suffix', 'overwrite', 'fail')",
      name: "migration_plan_steps_conflict_policy_enum"
  end
end
