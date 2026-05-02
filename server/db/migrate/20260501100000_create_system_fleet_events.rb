# frozen_string_literal: true

# Persistent log of fleet observability events. Every signal the sensors
# emit, every decision the engine makes, every skill the executor runs
# leaves a row here. Used by:
#   - SystemFleetChannel for live UI subscriptions
#   - Boot Replay Viewer (Track F-12) for forensic deterministic replay
#   - AttributeFailureExecutor to walk recent changes when an instance dies
#   - ComplianceSnapshotService for audit evidence
#
# Reference: Golden Eclipse plan M7 — fleet observability surface.
class CreateSystemFleetEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :system_fleet_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :account, null: false, foreign_key: { to_table: :accounts }, type: :uuid

      # Event taxonomy: kind matches signal action_category vocabulary
      # ("system.module_drift", "system.instance_silent", etc.) plus
      # decision-class kinds ("decision.deduped", "decision.proceeded",
      # "decision.pending") and skill-class kinds ("skill.invoked",
      # "skill.failed").
      t.string :kind, null: false
      t.string :severity, null: false, default: "low"

      # Optional foreign keys to the resources the event relates to.
      # Indexed individually so dashboards can filter by any one.
      t.uuid :node_id
      t.uuid :node_instance_id
      t.uuid :node_module_id
      t.uuid :node_module_version_id
      t.uuid :certificate_id
      t.uuid :cve_id

      # Free-form structured payload. Schema is per-kind; consumers
      # should treat unknown keys as forward-compatible additions.
      t.jsonb :payload, default: -> { "'{}'::jsonb" }, null: false

      # Correlation chain: groups events from the same tick / decision /
      # skill invocation. Same correlation_id ↔ same logical operation.
      t.string :correlation_id

      # Source: which subsystem emitted (sensor name, decision_engine,
      # learning_extractor, agent, etc.).
      t.string :source

      t.datetime :emitted_at, default: -> { "now()" }, null: false

      t.timestamps

      t.index :kind
      t.index :severity
      t.index :emitted_at
      t.index :correlation_id
      t.index :node_instance_id
      t.index :node_module_id
      t.index [:account_id, :emitted_at]
      t.index :payload, using: :gin
    end

    add_check_constraint :system_fleet_events,
      "severity IN ('low', 'medium', 'high', 'critical')",
      name: "ck_fleet_events_severity"
  end

  def down
    drop_table :system_fleet_events
  end
end
