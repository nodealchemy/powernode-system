# frozen_string_literal: true

# Each running NodeInstance auto-registers as a peer when it heartbeats.
# Peers declare capabilities + skills and accept remote task delegation
# from operators or other AI agents.
#
# Lifecycle:
#   - Created by Go agent's first announce after enrollment
#   - Updated on subsequent announces (capability changes, module attach/detach)
#   - Auto-disabled (not destroyed) on instance termination
#   - Operators activate peers explicitly before they appear in the
#     workspace mention picker (default disabled to prevent accidental
#     capability disclosure)
#
# Reference: comprehensive stabilization sweep P6; Golden Eclipse F-3.
class CreateSystemNodeInstancePeers < ActiveRecord::Migration[8.1]
  def change
    create_table :system_node_instance_peers, id: :uuid do |t|
      t.references :node_instance, null: false, type: :uuid,
                   foreign_key: { to_table: :system_node_instances },
                   index: { unique: true }
      t.references :account, null: false, type: :uuid, foreign_key: true
      t.string :handle, null: false  # @instance-<short-id> format
      t.boolean :enabled, default: false, null: false  # operator-activation gated
      t.string :status, default: "registered", null: false  # registered|active|degraded|disconnected
      t.jsonb :capabilities, default: {}
      t.jsonb :declared_skills, default: []
      t.string :addresses, array: true, default: []
      t.decimal :trust_score, precision: 5, scale: 4, default: 0.5  # 0.0..1.0
      t.integer :daily_decision_budget, default: 10, null: false
      t.integer :daily_decision_used, default: 0, null: false
      t.datetime :daily_decision_window_start
      t.datetime :first_announced_at
      t.datetime :last_announced_at
      t.datetime :last_executed_at
      t.bigint :execution_count, default: 0, null: false
      t.bigint :execution_failure_count, default: 0, null: false
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :system_node_instance_peers, [:account_id, :handle], unique: true
    add_index :system_node_instance_peers, :enabled
    add_index :system_node_instance_peers, :status
  end
end
