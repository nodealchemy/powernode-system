# frozen_string_literal: true

# Campaign 01a07025, increment app-2 — durable per-fingerprint state for a
# STANDING fleet signal.
#
# THE DEFECT THIS REPLACES. DecisionEngine's cross-tick dedup lives entirely in
# Rails.cache (a 600s TTL key per fingerprint), so the only durable trace a
# standing condition left was the `decision.deduped` FleetEvent the engine
# emitted on EVERY tick for EVERY deduped fingerprint. LearningExtractor
# already names the volume — "zero-information buckets: deduped decisions
# (29k/day live)" — and the ops-hub tick of 2026-09-05 04:48Z shows what it
# bought: `signal_count 25, decision_count 25, by_decision {deduped: 25},
# approved_executed 0, remediations_recorded 0`. Twenty-five standing
# conditions, twenty-five events a minute, nobody told about any of them.
#
# THE EVENT STREAM STOPS BEING THE RECORD; THIS ROW IS. The row counts the
# re-detections (tick_count), remembers when the episode started
# (first_seen_at) and when it was last seen, and carries the two rate limiters
# the engine and the notify lane claim against (last_dedup_event_at,
# last_notified_at) plus the escalation ledger (escalated_at,
# escalation_count). Nothing here is a cache: Rails.cache on the hub is
# memory_store — per-Puma-process and flushed on restart — which is exactly why
# FleetAutonomyService#open_operator_request? reads the DATABASE and says so.
#
# ONE ROW PER [account, fingerprint], not per [account, kind, fingerprint]: a
# sensor's fingerprint already embeds its kind, and a unique index on the pair
# is what lets the engine upsert under a row lock without two ticks
# double-counting. signal_kind rides along as the human-readable half.
#
# Deliberately NOT a snapshot of the signal payload. The payload is already
# durable on the FleetEvent the sense pass emits (EventBroadcaster#emit_signal!
# runs before any routing, untouched by this increment); duplicating it here
# would put a second, staler copy of the same facts in front of an operator.
class CreateSystemFleetSignalStates < ActiveRecord::Migration[8.0]
  def change
    create_table :system_fleet_signal_states, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :account_id, null: false
      # The sensor's own per-resource key — the same value DecisionEngine
      # dedups on, RemediationValidator scores by, and EventBroadcaster uses as
      # a correlation_id. Not an FK to anything: a fingerprint outlives the row
      # that produced it, which is the whole point of an aging window.
      t.string :fingerprint, null: false
      t.string :signal_kind, null: false

      # The EPISODE. first_seen_at restarts when the fingerprint has been
      # absent longer than the engine's episode_reset window — a condition that
      # cleared and came back is a new standing episode, not a continuation,
      # and must not inherit a tick_count that would escalate it instantly.
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.integer :tick_count, null: false, default: 0
      t.string :last_decision

      # Rate-limit claims. Both are "when did this lane last actually emit",
      # never "when was it last due" — a due-check that does not stamp is how a
      # heartbeat degenerates back into a per-tick stream.
      t.datetime :last_dedup_event_at
      t.datetime :last_notified_at

      # The escalation ledger. escalated_at/escalation_count are a RECORD, not
      # the brake: re-escalation is bounded by an OPEN ApprovalRequest
      # (FleetAutonomyService#open_operator_request?), the same terminal state
      # DecisionEngine#escalate_stuck_remediation! uses. Gating on this column
      # instead would alert once and then stay silent for the life of the row,
      # even after an operator resolved the request and the condition stood.
      t.datetime :escalated_at
      t.integer :escalation_count, null: false, default: 0

      t.timestamps
    end

    # Upsert key. Unique so two ticks cannot leave two rows disagreeing about
    # how long one condition has stood.
    add_index :system_fleet_signal_states, %i[account_id fingerprint], unique: true,
              name: "idx_fleet_signal_states_on_account_and_fingerprint"
    # The operator query this table exists to make answerable: "what has been
    # standing, for how long, and has anyone been told".
    add_index :system_fleet_signal_states, %i[account_id last_seen_at],
              name: "idx_fleet_signal_states_on_account_and_last_seen"
  end
end
