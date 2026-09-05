# frozen_string_literal: true

require "rails_helper"

# Campaign 01a07025 increment app-2 — standing-signal hygiene.
#
# THE DEFECT, measured on ops-hub 2026-09-05 04:48Z. Every 60s tick re-detected
# the same 25 standing conditions and did nothing about any of them, loudly:
# `fleet.tick_complete` reported `signal_count 25, decision_count 25,
# by_decision {deduped: 25}, approved_executed 0, remediations_recorded 0`. The
# dedupe branch of DecisionEngine#decide emitted a `decision.deduped` FleetEvent
# on EVERY tick for EVERY standing fingerprint — LearningExtractor already calls
# these "zero-information buckets ... 29k/day" — while nothing anywhere ever
# told a person that 12 config-drift assignments had stood unapplied since July
# and a CRITICAL sdwan hub-unreachable had been re-firing since August.
#
# Both halves are asserted here and neither is worth anything alone: suppressing
# the event stream without escalating buries the condition, and escalating
# without suppressing keeps the flood. Every assertion is on a ROW or an event
# COUNT — never on a status code and never on a log line.
RSpec.describe "standing fleet signal hygiene" do
  let(:account)   { create(:account) }
  let!(:operator) { create(:user, account: account) }
  let(:agent)     { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service)   { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
  let(:engine)    { System::Fleet::DecisionEngine.new(autonomy_service: service) }

  # The escalation forces require_approval, and create_pending_approval needs a
  # chain to mint against. trigger_type "autonomy_action" + a name matching
  # /fleet/ is what FleetAutonomyService#fleet_approval_chain resolves.
  let!(:chain) do
    create(:ai_approval_chain, account: account, trigger_type: "autonomy_action",
                               status: "active", name: "Fleet Autonomy Chain")
  end

  # The engine's cross-tick dedup is Rails.cache-backed (memory_store in test,
  # shared across examples), so the standing-signal path only runs if the cache
  # starts clean.
  before { Rails.cache.clear }

  def seed_policy!(category, policy)
    Ai::InterventionPolicy.create!(
      account: account, ai_agent_id: agent.id, scope: "agent",
      action_category: category, policy: policy, is_active: true
    )
  end

  def tick!(fingerprint: "cert_expiring:c-standing", kind: "system.cert_expiring")
    engine.decide(kind: kind, severity: :medium,
                  payload: { "certificate_id" => "c-standing" },
                  fingerprint: fingerprint)
  end

  def deduped_events
    System::FleetEvent.where(account_id: account.id, kind: "decision.deduped")
  end

  def escalation_notifications
    Notification.where(account_id: account.id, notification_type: "agent_escalation")
  end

  def fleet_approvals
    Ai::ApprovalRequest.where(account_id: account.id)
  end

  describe "the dedupe path keeps durable per-fingerprint state" do
    before { seed_policy!("system.cert_rotate", "auto_approve") }

    it "increments tick_count across simulated ticks instead of only re-emitting" do
      4.times { tick! }

      state = System::Fleet::SignalState.find_by(account_id: account.id,
                                                 fingerprint: "cert_expiring:c-standing")
      expect(state).to be_present,
                       "the standing condition must leave a row — the state row IS the record"
      expect(state.signal_kind).to eq("system.cert_expiring")
      # Tick 1 is a real decision; ticks 2..4 are deduped re-detections.
      expect(state.tick_count).to eq(3)
      expect(state.first_seen_at).to be_present
      expect(state.last_seen_at).to be >= state.first_seen_at
    end

    it "emits at most two decision.deduped events over a window inside one heartbeat" do
      SiteSetting.set("system.fleet.signal_state.heartbeat_seconds", 3600,
                      setting_type: "integer")
      # High enough that this example measures suppression only.
      SiteSetting.set("system.fleet.signal_state.escalate_after_ticks", 500,
                      setting_type: "integer")

      6.times { tick! }

      expect(deduped_events.count).to be <= 2,
                                      "5 deduped ticks inside one heartbeat must not mint 5 events"
      expect(deduped_events.count).to be >= 1,
                                      "the first dedupe must still be visible — silence is not hygiene"
    end
  end

  describe "aging escalates exactly once to something a human sees" do
    before do
      seed_policy!("system.cert_rotate", "auto_approve")
      SiteSetting.set("system.fleet.signal_state.escalate_after_ticks", 2, setting_type: "integer")
      SiteSetting.set("system.fleet.signal_state.heartbeat_seconds", 3600, setting_type: "integer")
    end

    it "mints one approval row and one escalation per operator, then stops while it is open" do
      operators = account.users.active.count
      expect(operators).to be >= 1, "the fanout assertion below is only meaningful with an operator set"

      4.times { tick! }

      expect(fleet_approvals.count).to eq(1),
                                       "a standing, unremediated signal must reach the approval inbox exactly once"
      # ONE escalation, fanned out once to each operator — not one escalation
      # per tick. The fingerprint dimension is what pins "one escalation".
      expect(escalation_notifications.count).to eq(operators),
                                                "an approval nobody is told about is not an escalation"
      expect(escalation_notifications.map { |n| n.metadata["fingerprint"] }.uniq)
        .to eq([ "cert_expiring:c-standing" ])

      request = fleet_approvals.first
      payload = request.request_data["payload"]
      expect(payload["standing_signal"]).to be true
      expect(payload["remediation_action"]).to eq("system.cert_rotate")
      expect(payload["signal_fingerprint"]).to eq("cert_expiring:c-standing")

      state = System::Fleet::SignalState.find_by(account_id: account.id,
                                                 fingerprint: "cert_expiring:c-standing")
      expect(state.escalated_at).to be_present
      expect(state.escalation_count).to eq(1)

      # An escalation already open must not re-escalate. Assert the ROWS, not
      # the returned decision: a lane that returns "already open" while still
      # minting is the exact failure this guards.
      approvals_before     = fleet_approvals.count
      notifications_before = escalation_notifications.count
      4.times { tick! }
      expect(fleet_approvals.count).to eq(approvals_before)
      expect(escalation_notifications.count).to eq(notifications_before)
      expect(state.reload.escalation_count).to eq(1)
    end

    it "emits one high-severity standing-signal event alongside the escalation" do
      6.times { tick! }

      events = System::FleetEvent.where(
        account_id: account.id,
        kind: System::Fleet::DecisionEngine::STANDING_SIGNAL_EVENT_KIND
      )
      expect(events.count).to eq(1)
      expect(events.first.severity).to eq("high")
      expect(events.first.payload["fingerprint"]).to eq("cert_expiring:c-standing")
    end

    it "does not escalate a fingerprint that HAS a remediation on record" do
      System::Fleet::RemediationOutcome.create!(
        account: account, signal_kind: "system.cert_expiring",
        fingerprint: "cert_expiring:c-standing", action_category: "system.cert_rotate",
        status: "effective", acted_at: 2.hours.ago, settle_until: 1.hour.ago,
        validated_at: 1.hour.ago
      )

      6.times { tick! }

      expect(fleet_approvals.count).to eq(0),
                                       "the lane exists for signals nothing ever acted on"
      expect(escalation_notifications.count).to eq(0)
    end

    it "does not escalate below the tick threshold" do
      SiteSetting.set("system.fleet.signal_state.escalate_after_ticks", 50, setting_type: "integer")

      4.times { tick! }

      expect(fleet_approvals.count).to eq(0)
      expect(escalation_notifications.count).to eq(0)
    end
  end
end
