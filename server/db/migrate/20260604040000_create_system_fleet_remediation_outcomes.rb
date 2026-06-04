# frozen_string_literal: true

# AI/MCP workload substrate — self-improvement Phase 0 (the validate step).
# Ground-truth effectiveness record for an autonomous fleet remediation: when the
# autonomy loop PROCEEDs an action for a signal it records a pending outcome
# keyed by the signal fingerprint; a later tick re-senses and scores it
# effective / ineffective. Closes the sense -> act -> VALIDATE arc.
class CreateSystemFleetRemediationOutcomes < ActiveRecord::Migration[8.1]
  def change
    create_table :system_fleet_remediation_outcomes, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true,
                   index: { name: "idx_fleet_remediation_outcomes_account" }
      t.uuid :agent_id # the fleet-autonomy agent; no cross-namespace FK
      t.string :signal_kind, null: false
      t.string :fingerprint, null: false # match key: signal cleared => effective
      t.string :action_category
      t.string :correlation_id
      t.string :resource_ref
      t.string :status, null: false, default: "pending" # pending|effective|ineffective|inconclusive
      t.datetime :acted_at, null: false
      t.datetime :settle_until, null: false # don't validate before this (let the action settle)
      t.datetime :validated_at
      t.jsonb :metadata, default: {}
      t.timestamps
    end

    add_index :system_fleet_remediation_outcomes, :fingerprint
    # The pending-due query: account's pending outcomes whose settle window elapsed.
    add_index :system_fleet_remediation_outcomes, %i[account_id status settle_until],
              name: "idx_fleet_remediation_pending_due"
  end
end
