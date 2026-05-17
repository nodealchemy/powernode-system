# frozen_string_literal: true

# Per-module Service-Level Objective definitions. Each row declares the
# operational targets a module must meet (uptime %, error rate cap,
# latency p99 cap). System::Slo::ScoreEvaluator computes current
# performance against these and emits system.slo_violation signals
# when targets aren't being hit.
#
# Reference: Golden Eclipse plan F item — module SLO scoring (creative
# extension; integrates with the FleetAutonomyService signal pipeline).
class CreateSystemSloDefinitions < ActiveRecord::Migration[8.1]
  def up
    create_table :system_slo_definitions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :node_module, null: false,
        foreign_key: { to_table: :system_node_modules }, type: :uuid

      t.string  :name, null: false                          # human label
      t.decimal :uptime_target_pct, precision: 5, scale: 2  # e.g., 99.95
      t.decimal :error_rate_max_pct, precision: 5, scale: 2 # e.g., 0.10
      t.integer :latency_p99_max_ms                          # e.g., 1500

      # Window for evaluation (e.g., "30d", "7d", "1h")
      t.string :window, null: false, default: "1d"

      # Whether this SLO triggers autonomy actions on violation. When false,
      # SloViolationSensor still records a FleetEvent but doesn't gate
      # through FleetAutonomyService.
      t.boolean :enforces_autonomy, null: false, default: false

      t.jsonb :metadata, default: -> { "'{}'::jsonb" }, null: false
      t.timestamps

      # NOTE: `t.references :node_module` above already creates the
      # `index_system_slo_definitions_on_node_module_id` index. An
      # explicit `t.index :node_module_id` here would duplicate it and
      # raise PG::DuplicateTable. Per the project's t.references rule,
      # only customize the auto-generated index via the references
      # declaration itself.
      t.index [:node_module_id, :name], unique: true, name: "ix_slo_module_name_unique"
    end
  end

  def down
    drop_table :system_slo_definitions
  end
end
