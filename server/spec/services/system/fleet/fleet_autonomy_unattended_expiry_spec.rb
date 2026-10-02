# frozen_string_literal: true

require "rails_helper"

# IMP-44ae4d4b2811 — a standing signal's approval expires unattended (the fleet
# chain is 4h / reject), the rejected-cooldown that follows is 1h (4h for the
# advancement actions), and the still-standing signal then mints a FRESH request:
# a new card every ~5h per condition, ~90 auto-rejections a day on ops-hub, none
# of them ever seen by a person. A clock-fired rejection is not an operator's
# answer, so the same condition now backs off, escalating, instead of re-parking
# at a fixed beat. An explicit operator rejection keeps the cooldown it has.
RSpec.describe System::Fleet::FleetAutonomyService, "unattended expiry backoff" do
  before do
    skip "requires Ai::ApprovalChain (business extension)" unless defined?(::Ai::ApprovalChain)
  end

  let(:account)  { create(:account) }
  let(:agent)    { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service)  { described_class.new(account: account, agent: agent) }
  let(:operator) { create(:user, account: account) }
  let(:category) { "system.instance_reprovision" }

  before do
    create(:ai_approval_chain, account: account, trigger_type: "autonomy_action", name: "Fleet Autonomy Actions")
    Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                   action_category: category, policy: "require_approval", is_active: true)
  end

  def gate!(instance: "inst-1", metadata: nil)
    service.gate_action!(category, metadata: metadata || { instance_id: instance },
                                   reasoning: { summary: "instance silent" })
  end

  # The clock fires: no decision row, exactly what #expire_stale_approvals! does.
  def let_it_expire!(request = Ai::ApprovalRequest.order(:created_at).last, ago: 2.hours)
    request.update_columns(expires_at: 5.hours.ago)
    service.send(:expire_stale_approvals!)
    request.reload.tap do |r|
      expect(r.status).to eq("rejected")
      r.update_columns(completed_at: ago.ago)
    end
  end

  def mints?(**args)
    before = Ai::ApprovalRequest.count
    gate!(**args)
    Ai::ApprovalRequest.count > before
  end

  it "suppresses a re-mint of the same condition for a day after an unattended expiry, not for an hour" do
    gate!
    let_it_expire!(ago: 2.hours) # the old 1h cooldown has passed

    expect(mints?).to be(false)
  end

  it "re-mints once the cooldown has passed, so the condition is not lost" do
    gate!
    let_it_expire!(ago: 25.hours)

    expect(mints?).to be(true)
  end

  it "backs off: each further unattended expiry of the same condition doubles the wait, up to a cap" do
    gate!
    let_it_expire!(ago: 25.hours)
    gate!
    let_it_expire!(ago: 25.hours) # second expiry: now 48h

    expect(mints?).to be(false)

    Ai::ApprovalRequest.rejected.update_all(completed_at: 49.hours.ago)
    expect(mints?).to be(true)
  end

  it "caps the wait at seven days, however many times the condition has expired" do
    5.times do
      gate!
      let_it_expire!(ago: 8.days) # old enough to re-mint each time, still inside the 30-day count
    end
    gate!
    let_it_expire!(ago: 6.days)

    expect(mints?).to be(false) # 6 days < the 7-day cap

    Ai::ApprovalRequest.rejected.order(:completed_at).last.update_columns(completed_at: 8.days.ago)
    expect(mints?).to be(true)  # uncapped, six expiries would wait 32 days
  end

  it "does not stretch an OPERATOR's rejection: a person answered, the existing cooldown stands" do
    gate!
    request = Ai::ApprovalRequest.last
    request.record_decision!(approver: operator, decision: "rejected")
    request.reload.update_columns(completed_at: 2.hours.ago)

    expect(mints?).to be(true)
  end

  it "keeps another condition on the same action category unaffected" do
    gate!(instance: "inst-1")
    let_it_expire!(ago: 2.hours)

    expect(mints?(instance: "inst-2")).to be(true)
  end

  it "leaves the action-level fallback (no natural key) on the short cooldown: it would hide unrelated conditions" do
    gate!(metadata: { note: "no key" })
    let_it_expire!(ago: 2.hours)

    expect(mints?(metadata: { note: "no key" })).to be(true)
  end

  it "tells open_operator_request? the same, so the stuck and standing lanes do not re-mint inside the backoff either" do
    gate!
    let_it_expire!(ago: 2.hours)

    expect(service.open_operator_request?(category, metadata: { instance_id: "inst-1" })).to be(true)

    Ai::ApprovalRequest.rejected.update_all(completed_at: 25.hours.ago)
    expect(service.open_operator_request?(category, metadata: { instance_id: "inst-1" })).to be(false)
  end

  describe "what must not be hidden (review of IMP-44ae4d4b2811)" do
    it "never backs off the security categories: a coarse key would silence every later probe for a week" do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.instance_terminate", policy: "require_approval", is_active: true)
      meta = { module_id: "canary-module" }
      service.gate_action!("system.instance_terminate", metadata: meta, reasoning: { summary: "canary probe" })
      let_it_expire!(ago: 2.hours)

      expect(service.open_operator_request?("system.instance_terminate", metadata: meta)).to be(false)
      before = Ai::ApprovalRequest.count
      service.gate_action!("system.instance_terminate", metadata: meta, reasoning: { summary: "canary probe again" })

      expect(Ai::ApprovalRequest.count).to eq(before + 1)
    end

    it "never backs off a critical signal, whatever its category" do
      meta = { instance_id: "inst-1", signal_severity: "critical" }
      gate!(metadata: meta)
      let_it_expire!(ago: 2.hours)

      expect(mints?(metadata: meta)).to be(true)
    end

    it "treats a different fingerprint on the same key as a new condition, and the same one as the old" do
      gate!(metadata: { instance_id: "inst-1", signal_fingerprint: "fp-a" })
      let_it_expire!(ago: 2.hours)

      expect(mints?(metadata: { instance_id: "inst-1", signal_fingerprint: "fp-a" })).to be(false)
      expect(mints?(metadata: { instance_id: "inst-1", signal_fingerprint: "fp-b" })).to be(true)
    end

    it "treats a higher severity of the same fingerprint as a new fact" do
      gate!(metadata: { instance_id: "inst-1", signal_fingerprint: "fp-a", signal_severity: "medium" })
      let_it_expire!(ago: 2.hours)

      expect(mints?(metadata: { instance_id: "inst-1", signal_fingerprint: "fp-a", signal_severity: "high" })).to be(true)
    end

    it "restarts the count once a person has answered a request on the condition: a recurrence is a new incident" do
      gate!
      first = let_it_expire!(ago: 25.hours)
      gate!
      let_it_expire!(ago: 25.hours) # two expiries: 48h wait, still suppressed
      expect(mints?).to be(false)

      Ai::ApprovalDecision.create!(approval_request: first, approver: operator, decision: "approved",
                                   comments: "handled", step_number: 1, origin: Ai::ApprovalDecision::REST_SESSION)
      first.update_columns(completed_at: 2.hours.ago)

      expect(mints?).to be(true)
    end

    it "keeps counting a request that was only delegated or abstained on and then expired: that is still the clock" do
      gate!
      request = let_it_expire!(ago: 2.hours)
      Ai::ApprovalDecision.create!(approval_request: request, approver: operator, decision: "abstained",
                                   comments: "not mine", step_number: 1, origin: Ai::ApprovalDecision::REST_SESSION)

      expect(mints?).to be(false)
    end

    it "does not back off an advisory request" do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.capability_gap_review", policy: "require_approval", is_active: true)
      meta = { "module_id" => "m-1", "signal_fingerprint" => "capability_gap:m-1:x" }
      service.gate_action!("system.capability_gap_review", metadata: meta, reasoning: { summary: "gap" }, advisory: true)
      request = Ai::ApprovalRequest.last
      request.update_columns(expires_at: 5.hours.ago)
      service.send(:expire_stale_approvals!)
      request.reload.update_columns(completed_at: 2.hours.ago)

      before = Ai::ApprovalRequest.count
      service.gate_action!("system.capability_gap_review", metadata: meta, reasoning: { summary: "gap" }, advisory: true)
      expect(Ai::ApprovalRequest.count).to eq(before + 1)
    end
  end

  describe "tuning (DB-driven, falls back to the constants)" do
    it "reads the base wait from system.fleet.unattended_expiry_cooldown_seconds" do
      create(:site_setting, key: "system.fleet.unattended_expiry_cooldown_seconds", value: "7200", setting_type: "integer") if defined?(SiteSetting)
      gate!
      let_it_expire!(ago: 3.hours)

      expect(mints?).to be(true) # 3h > the 2h the setting allows
    end

    it "ignores a value that is not a positive whole number" do
      create(:site_setting, key: "system.fleet.unattended_expiry_cooldown_seconds", value: "abc", setting_type: "string") if defined?(SiteSetting)
      gate!
      let_it_expire!(ago: 2.hours)

      expect(mints?).to be(false)
    end
  end
end

# The acceptance note on the task: a standing signal with no skill and no applier
# never reaches the remediation-stuck escalation. That lane needs an ineffective
# RemediationOutcome streak, and an applier-less proceed must never write the
# outcome that feeds it. Pinned over EVERY such binding rather than a sample.
RSpec.describe System::Fleet::RemediationValidator, "applier-less lanes never feed the stuck escalation" do
  let(:account) { create(:account) }

  applier_less = System::Fleet::DecisionEngine::SIGNAL_BINDINGS.select do |kind, binding|
    binding[:skill].nil? && !System::Fleet::DecisionEngine::REMEDIATION_APPLIERS.key?(kind)
  end

  it "found the applier-less bindings (the enumeration itself is not vacuous)" do
    expect(applier_less.size).to be > 10
  end

  applier_less.each do |kind, binding|
    it "records no remediation outcome for a proceeded #{kind}" do
      decision = { decision: :proceed, gate: "notify_and_proceed", signal_kind: kind,
                   action_category: binding[:action_category], fingerprint: "fp-#{kind}",
                   correlation_id: "c" }
      signal = System::Fleet::Signal.new(kind: kind, severity: :low, payload: {}, fingerprint: "fp-#{kind}")

      expect { described_class.new(account: account).record_proceeded!(decisions: [ decision ], signals: [ signal ]) }
        .not_to change(System::Fleet::RemediationOutcome, :count)
    end
  end
end
