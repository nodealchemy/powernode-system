# frozen_string_literal: true

# Environment campaign, increment 4 — the promotion ladder.
#
# A PIN is the version an environment runs of a module. An environment that
# follows publishes (Ai::Environment#auto_promote_on_publish) has no pins:
# its nodes serve the module's current_version, exactly as before. A PINNED
# environment (staging, prod by default) serves what was promoted into it —
# one row per (module, environment) — and a publish never touches it. A
# version climbs the ladder one rung at a time through
# NodeModule#promote_in_environment!, each step gated in the target plane.
#
# A pinned environment with NO pin for a module serves nothing of it. So the
# environments that are ALREADY pinned when this lands (staging, prod by
# default) are frozen here at every module's current version — what their
# nodes run today — and nothing changes at deploy time. From then on a flip
# to pinned freezes the same way (System::ModuleEnvironmentPin::PromotionModeListener).
class CreateSystemModuleEnvironmentPins < ActiveRecord::Migration[8.0]
  def up
    create_pins_table
    execute <<~SQL
      INSERT INTO system_module_environment_pins
        (id, account_id, node_module_id, environment_id, node_module_version_id,
         promoted_by_type, promoted_at, metadata, created_at, updated_at)
      SELECT uuidv7(), m.account_id, m.id, e.id, m.current_version_id,
             'pin_freeze', NOW(), '{}'::jsonb, NOW(), NOW()
      FROM system_node_modules m
      JOIN ai_environments e ON e.account_id = m.account_id AND e.auto_promote_on_publish = FALSE
      WHERE m.current_version_id IS NOT NULL
    SQL
  end

  def down
    drop_table :system_module_environment_pins
  end

  def create_pins_table
    create_table :system_module_environment_pins, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true
      t.references :node_module, null: false, type: :uuid, foreign_key: { to_table: :system_node_modules }
      # A deleted environment or version takes its pins with it (a core-side
      # environment delete cannot know this table; the FK does).
      t.references :environment, null: false, type: :uuid, foreign_key: { to_table: :ai_environments, on_delete: :cascade }
      t.references :node_module_version, null: false, type: :uuid,
                                         foreign_key: { to_table: :system_node_module_versions, on_delete: :cascade }
      t.uuid :promoted_by_id
      t.string :promoted_by_type
      t.datetime :promoted_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :system_module_environment_pins, %i[node_module_id environment_id], unique: true,
              name: "index_module_environment_pins_on_module_and_environment"
  end
end
