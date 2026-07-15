# frozen_string_literal: true

# Campaign 019f6084 inc-M — the durable state machine behind on-demand
# capability fulfillment (System::Ai::Skills::FulfillCapabilityRequestExecutor).
#
# Replaces the synchronous skill that slept through the module-build barrier and
# RE-COMPUTED its plan across the approval boundary (a TOCTOU: the plan an
# operator approved could differ from the plan that executed). One row per
# fulfillment request; the approved plan is FROZEN in `plan` and is the ONLY
# thing the advance orchestrator ever executes — approval is an out-of-band
# state transition (composed → approved), never an in-band re-compose.
#
# AASM: composed → approved → materializing → building → templated →
# provisioning → smoking → ready → (failed | expired). Every artifact the run
# creates (build batch, template, instances, materialized modules) hangs off
# this row so a failure can be rolled back and every run is auditable. Mirrors
# System::ModuleBuildBatch's AASM + denormalized-counters + per-transition
# timestamp columns.
class CreateSystemFulfillmentRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :system_fulfillment_requests, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :account_id, null: false
      t.uuid :requested_by_user_id

      t.text :request, null: false
      t.string :state, null: false, default: "composed"

      # The FROZEN approved plan (display payload + a replayable `execution`
      # context). The advance orchestrator executes THIS, never a re-compose.
      t.jsonb :plan, null: false, default: {}
      # Best-effort hourly cost estimate — the input to the approved→materializing
      # budget gate (previously computed and compared to NOTHING).
      t.jsonb :cost_estimate, null: false, default: {}

      # Denormalized closure / artifact accounting (mirrors ModuleBuildBatch's
      # planned/succeeded/failed counters).
      t.jsonb :reused_modules, null: false, default: []
      t.jsonb :materialized_modules, null: false, default: []
      t.jsonb :materialized_module_ids, null: false, default: []
      t.jsonb :node_instance_ids, null: false, default: []
      t.integer :reused_count, null: false, default: 0
      t.integer :materialized_count, null: false, default: 0
      t.integer :instance_count, null: false, default: 0

      # Artifacts (plain uuids, not FK-backed — mirrors CiRunnerLease#git_runner_id;
      # the row is the durable accounting record even after an artifact is torn down).
      t.uuid :build_batch_id
      t.uuid :template_id

      t.jsonb :smoke
      t.jsonb :parked, null: false, default: []
      t.text :error

      # Task-scoped lease: the record-level expiry the reaper uses to terminate a
      # ready fulfillment's instances (per-instance leases live on node_instances).
      t.integer :lease_ttl_seconds
      t.datetime :expires_at

      # Per-transition timestamps (stamped inline by the AASM `before` blocks so a
      # single transition save persists the state + its timestamp atomically).
      t.datetime :approved_at
      t.datetime :materializing_at
      t.datetime :building_at
      t.datetime :templated_at
      t.datetime :provisioning_at
      t.datetime :smoking_at
      t.datetime :ready_at
      t.datetime :failed_at
      t.datetime :expired_at

      t.timestamps
    end

    add_index :system_fulfillment_requests, :account_id
    add_index :system_fulfillment_requests, :state
    add_index :system_fulfillment_requests, :build_batch_id
    add_index :system_fulfillment_requests, :template_id
    add_index :system_fulfillment_requests, :expires_at
    # Rate-limit gate query: fulfillments an account STARTED in the last hour.
    add_index :system_fulfillment_requests, [ :account_id, :materializing_at ],
              name: "idx_fulfillment_requests_account_rate"
  end
end
