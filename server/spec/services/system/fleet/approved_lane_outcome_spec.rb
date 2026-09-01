# frozen_string_literal: true

require "rails_helper"

# IMP-31f1e5f9b365 — the VALIDATE arm of the require_approval lane.
#
# F3-01 gave the require_approval lane an ACT arm
# (FleetAutonomyService#execute_approved_actions! ->
# DecisionEngine#execute_approved!), but nothing ever scored what it did.
# RemediationValidator#record_proceeded! only ever saw decisions from
# #decide_all, and a require_approval decision is :pending there — so every
# remediation an operator approved and the loop then EXECUTED produced no
# RemediationOutcome, no effectiveness score, no ineffective streak, and no
# F3-11 escalation. The lane acted blind.
#
# The row must correspond to an EXECUTION, not an approval: an approval that
# never ran, or ran with applied:false, must mint NOTHING, or the pending row
# scores ineffective every settle window and the F3-11 streak manufactures the
# false fleet.remediation_stuck HIGH escalation the validator's
# non-remediating exemption exists to prevent.
RSpec.describe "Approved-lane remediation outcomes (IMP-31f1e5f9b365)" do
  before do
    skip "requires Ai::ApprovalChain (business extension)" unless defined?(::Ai::ApprovalChain)
  end

  let(:account) { create(:account) }
  let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service) { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
  let(:engine)  { System::Fleet::DecisionEngine.new(autonomy_service: service) }
  let(:validator) { System::Fleet::RemediationValidator.new(account: account, agent: agent) }

  let(:chain) do
    create(:ai_approval_chain, account: account,
           trigger_type: "autonomy_action", name: "Fleet Autonomy Actions")
  end

  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance) do
    create(:system_node_instance, :running, node: node, variety: "cloud",
           cloud_instance_id: "vm-silent-1")
  end

  # The fingerprint a sensor actually emits: deterministic and per-resource, so
  # it re-emits verbatim on every later tick while the condition persists.
  let(:fingerprint) { "instance_silent:#{instance.id}" }

  def approved_request!(payload:, action_category: "system.instance_reprovision", created_at: nil)
    request = Ai::ApprovalRequest.create!(
      account: account, approval_chain: chain, source_type: "system_fleet",
      status: "approved", description: "Fleet action: #{action_category}",
      request_data: {
        "action_category" => action_category,
        "payload" => payload,
        "agent_role" => "fleet"
      }
    )
    request.update_columns(created_at: created_at) if created_at
    request
  end

  def silent_payload(extra = {})
    {
      "instance_id" => instance.id,
      "_sensor" => "SilentInstanceSensor",
      "signal_kind" => "system.instance_silent",
      "signal_severity" => "high",
      "signal_fingerprint" => fingerprint
    }.merge(extra)
  end

  def stub_reboot_ok!
    allow(System::InstanceControlService).to receive(:execute)
      .and_return(System::Runtime::Result.ok(data: { action: "reboot" }))
  end

  def outcomes
    System::Fleet::RemediationOutcome.where(account_id: account.id)
  end

  describe "an approved remediation that EXECUTES" do
    it "mints a pending RemediationOutcome keyed by the stamped signal fingerprint" do
      stub_reboot_ok!
      approved_request!(payload: silent_payload)

      expect {
        service.execute_approved_actions!(engine, validator: validator, correlation_id: "tick:abc")
      }.to change { outcomes.count }.by(1)

      outcome = outcomes.last
      expect(outcome.fingerprint).to eq(fingerprint)
      expect(outcome.status).to eq("pending")
      expect(outcome.signal_kind).to eq("system.instance_silent")
      expect(outcome.action_category).to eq("system.instance_reprovision")
      expect(outcome.correlation_id).to eq("tick:abc")
      expect(outcome.resource_ref).to eq(instance.id)
      expect(outcome.metadata["sensor"]).to eq("SilentInstanceSensor")
    end

    it "measures the settle window from the EXECUTION, not from the decision that was approved" do
      stub_reboot_ok!
      approved_request!(payload: silent_payload, created_at: 1.hour.ago)

      service.execute_approved_actions!(engine, validator: validator)

      outcome = outcomes.last
      window = System::Fleet::RemediationValidator::SETTLE_WINDOW
      # A window measured from the decision would already be an hour in the
      # past — the row would be due (and scored) before the work could land.
      expect(outcome.settle_until).to be > Time.current
      expect(outcome.acted_at).to be_within(30.seconds).of(Time.current)
      expect(outcome.settle_until).to be_within(30.seconds).of(Time.current + window)
    end

    it "is scored by the ORDINARY validate pass on a later tick — no second scoring path" do
      stub_reboot_ok!
      approved_request!(payload: silent_payload)
      service.execute_approved_actions!(engine, validator: validator)

      travel_to(3.minutes.from_now) do
        # Fingerprint gone from the fresh sense pass => the remediation stuck.
        expect(validator.validate_due!(current_signals: []))
          .to include(effective: 1)
      end
      expect(outcomes.last.status).to eq("effective")
    end

    it "scores INEFFECTIVE when the sensor re-emits the same fingerprint" do
      stub_reboot_ok!
      approved_request!(payload: silent_payload)
      service.execute_approved_actions!(engine, validator: validator)

      still_firing = System::Fleet::Signal.from_hash(
        "kind" => "system.instance_silent", "severity" => "high",
        "payload" => { "instance_id" => instance.id, "_sensor" => "SilentInstanceSensor" },
        "fingerprint" => fingerprint
      )

      travel_to(3.minutes.from_now) do
        expect(validator.validate_due!(current_signals: [ still_firing ]))
          .to include(ineffective: 1)
      end
      expect(outcomes.last.status).to eq("ineffective")
    end
  end

  describe "what must NOT mint a row" do
    # The guard's PRIMARY case, and deliberately not routed through an
    # already-exempt action_category: a remediating category, a present
    # fingerprint, no pending duplicate, and an applier that ran and FAILED.
    # If #executed_remediation? were deleted, this is the example that fails —
    # and the row it would mint is the false-escalation generator: pending,
    # fingerprint still firing, ineffective every window until F3-11 raises
    # fleet.remediation_stuck for a remediation that never landed.
    it "mints nothing when a remediating applier RAN and reported applied:false" do
      allow(System::InstanceControlService).to receive(:execute)
        .and_return(System::Runtime::Result.err(error: "provider rejected reboot"))
      request = approved_request!(payload: silent_payload)

      expect {
        service.execute_approved_actions!(engine, validator: validator)
      }.not_to change { outcomes.count }

      # Not vacuous: the applier really did run and really did report false.
      expect(System::InstanceControlService).to have_received(:execute)
      execution = request.reload.request_data["execution"]
      expect(execution["applied"]).to be false
      expect(execution["reason"]).to eq("provider rejected reboot")
      expect(request.request_data.dig("payload", "signal_fingerprint")).to eq(fingerprint)
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES)
        .not_to include("system.instance_reprovision")
    end

    it "mints nothing for an execution that reports applied:false (no applier)" do
      request = approved_request!(
        action_category: "system.observation",
        payload: { "signal_kind" => "system.unknown_kind", "signal_fingerprint" => "fp-noop" }
      )

      expect {
        service.execute_approved_actions!(engine, validator: validator)
      }.not_to change { outcomes.count }

      expect(request.reload.request_data.dig("execution", "applied")).to be false
    end

    it "mints nothing when the execution RAISES (the rescue stamps applied:false)" do
      approved_request!(payload: silent_payload)
      allow(engine).to receive(:execute_approved!).and_raise("boom")

      expect {
        service.execute_approved_actions!(engine, validator: validator)
      }.not_to change { outcomes.count }
    end

    it "mints nothing for an approval that is never executed" do
      # Approved but already stamped — the poller skips it entirely.
      stub_reboot_ok!
      request = approved_request!(payload: silent_payload)
      service.execute_approved_actions!(engine, validator: validator)
      outcomes.delete_all

      expect {
        service.execute_approved_actions!(engine, validator: validator)
      }.not_to change { outcomes.count }
      expect(request.reload.request_data["execution"]).to be_present
    end

    it "mints nothing for a pre-F3-01 request with no stamped fingerprint" do
      # execute_approved! synthesizes "approved:<request id>" for these. That
      # string is in no sense pass, so a row keyed on it would score EFFECTIVE
      # at the first due tick regardless of what the fleet actually did.
      stub_reboot_ok!
      request = approved_request!(payload: silent_payload.except("signal_fingerprint"))

      # record_proceeded! must not even be reached: its own blank check would
      # also stop a "" fingerprint, so asserting only on the row count cannot
      # tell this guard from that one.
      expect(validator).not_to receive(:record_proceeded!)
      expect {
        service.execute_approved_actions!(engine, validator: validator)
      }.not_to change { outcomes.count }

      # The replay still HAPPENED — it is the scoring that is refused.
      expect(request.reload.request_data.dig("execution", "applied")).to be true
      expect(engine.signal_from_approval(request).fingerprint).to eq("approved:#{request.id}")
      expect(outcomes.where("fingerprint LIKE 'approved:%'")).to be_empty
    end

    it "inherits the non-remediating-category exemption" do
      stub_reboot_ok!
      request = approved_request!(action_category: "system.node_lkg_investigate",
                                  payload: silent_payload)

      expect {
        service.execute_approved_actions!(engine, validator: validator)
      }.not_to change { outcomes.count }

      # The CATEGORY is what suppressed it — everything else about this
      # request would have minted (see the first example, which differs only
      # in action_category).
      expect(request.reload.request_data.dig("execution", "applied")).to be true
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES)
        .to include("system.node_lkg_investigate")
    end

    # IMP-31f1e5f9b365 — the failure mode the reviewer of this change caught.
    # system.template_closure_drift is forced to require_approval always
    # (DecisionEngine#force_policy_for), so this change is what first brings it
    # into the validate arc. Its applier calls TemplateApplyService#apply!,
    # which creates exactly the assignment rows TemplateClosureDriftSensor
    # subtracts — the fingerprint is gone from the next pass BY CONSTRUCTION,
    # whether or not the node ever synced. Scored by fingerprint disappearance
    # it would read EFFECTIVE every time, forever: a fabricated 1.0 in the
    # ground truth the LEARN step consumes.
    it "mints nothing when the applier DECLARES its action self-clears the fingerprint" do
      approved_request!(action_category: "system.template_closure_apply",
                        payload: silent_payload)
      allow(engine).to receive(:execute_approved!).and_return(
        { applied: true, instance_id: instance.id, task_id: "task-1",
          command: "sync_modules", assignments_created: [ "nm-1" ],
          fingerprint_self_clearing: true }
      )

      expect {
        service.execute_approved_actions!(engine, validator: validator)
      }.not_to change { outcomes.count }
    end

    it "the self-clearing declaration does NOT suppress a declared deferral" do
      # Both flags on one result (the pivot arm of apply_template_closure_drift
      # returns exactly this). The deferral wins: its row is settled by the
      # declaration, never by fingerprint disappearance, so self-clearing
      # cannot corrupt it — and it is the only evidence an operator gets for a
      # lane that said it could not converge.
      approved_request!(action_category: "system.template_closure_apply",
                        payload: silent_payload)
      allow(engine).to receive(:execute_approved!).and_return(
        { applied: true, instance_id: instance.id, assignments_created: [ "nm-1" ],
          convergence_deferred: true, fingerprint_self_clearing: true,
          reason: "pivot-booted instance composes its module union at boot" }
      )

      expect {
        service.execute_approved_actions!(engine, validator: validator)
      }.to change { outcomes.count }.by(1)
      expect(outcomes.last.metadata["convergence_deferred"]).to be true
    end

    it "does not duplicate a pending outcome already open for the fingerprint" do
      stub_reboot_ok!
      System::Fleet::RemediationOutcome.create!(
        account: account, signal_kind: "system.instance_silent", fingerprint: fingerprint,
        status: "pending", acted_at: Time.current,
        settle_until: Time.current + System::Fleet::RemediationValidator::SETTLE_WINDOW
      )
      approved_request!(payload: silent_payload)

      expect {
        service.execute_approved_actions!(engine, validator: validator)
      }.not_to change { outcomes.count }
    end

    it "mints nothing when no validator is supplied (back-compatible call shape)" do
      stub_reboot_ok!
      approved_request!(payload: silent_payload)

      expect { service.execute_approved_actions!(engine) }.not_to change { outcomes.count }
    end
  end

  describe "a DECLARED deferred convergence" do
    it "mints the row the validator settles inconclusive, exactly as the proceed lane does" do
      approved_request!(payload: silent_payload)
      allow(engine).to receive(:execute_approved!).and_return(
        { applied: false, convergence_deferred: true,
          reason: "last module_sync failed with reboot_pending" }
      )

      expect {
        service.execute_approved_actions!(engine, validator: validator)
      }.to change { outcomes.count }.by(1)

      outcome = outcomes.last
      expect(outcome.metadata["convergence_deferred"]).to be true
      expect(outcome.metadata["deferred_reason"]).to match(/reboot_pending/)

      travel_to(3.minutes.from_now) do
        expect(validator.validate_due!(current_signals: [])).to include(inconclusive: 1)
      end
      expect(outcomes.last.status).to eq("inconclusive")
    end
  end

  describe "tick! integration" do
    it "the approved lane's row is minted during the tick and reported" do
      stub_reboot_ok!
      allow(service).to receive(:collect_signals).and_return([ [], [] ])
      allow(service).to receive(:collect_project_metrics!)
      approved_request!(payload: silent_payload)

      expect { service.tick! }.to change { outcomes.count }.by(1)
      expect(outcomes.last.fingerprint).to eq(fingerprint)
      expect(outcomes.last.correlation_id).to start_with("tick:")
    end
  end
end
