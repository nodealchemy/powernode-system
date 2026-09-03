# frozen_string_literal: true

require "rails_helper"

# IMP-0de0a6b4db59 — the surviving half of APO-2d (IMP-25949cfd28fd).
#
# APO-2d made FleetAutonomyService#notify_action leave a durable, broadcast
# System::FleetEvent (kind autonomy.notified) instead of terminating in
# Rails.logger. CveResponderService carries its OWN notify_and_proceed arm and
# its OWN #notify_action, which was out of that task's lane: it stayed one
# Rails.logger.info line — a security-domain notification that reached no
# operator surface at all, the same defect on the CVE side.
#
# Deliberately independent of Ai::ApprovalChain (business extension) so it runs
# in core mode too — cve_responder_service_spec.rb skips wholesale without it.
# This spec pins the EMIT: a durable FleetEvent carrying the fleet twin's event
# kind, correlated to the CVE signal. The surfaces that gain it are the two
# KIND-AGNOSTIC FleetEvent reads — system_recent_signals and
# system_inspect_correlation — plus the account's fleet-channel broadcast; the
# approval UI is NOT among them, because notify_and_proceed mints no
# Ai::ApprovalRequest. Nothing keys on autonomy.notified today; the shared kind
# is what lets the two notify lanes be read as one when something does.
RSpec.describe System::CveOps::CveResponderService, "notify_and_proceed operator record" do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account) }
  let(:provider) { create(:ai_provider) }
  let(:agent) do
    Ai::Agent.create!(
      account: account, creator: user, provider: provider,
      name: "CVE Responder", agent_type: "monitor", status: "active"
    )
  end
  let(:service) { described_class.new(account: account, agent: agent) }

  def seed_policy!(category, policy)
    ::Ai::InterventionPolicy.create!(
      account: account, ai_agent_id: agent.id, scope: "agent",
      action_category: category, policy: policy, is_active: true
    )
  end

  before do
    # The proceed half is not under test — keep the inline orchestrator inert.
    orchestrator = instance_double(::System::Ai::Skills::CveRemediationOrchestrationExecutor)
    allow(::System::Ai::Skills::CveRemediationOrchestrationExecutor).to receive(:new).and_return(orchestrator)
    allow(orchestrator).to receive(:execute).and_return({ success: true, data: {} })
  end

  it "emits a durable, broadcast FleetEvent for a notify_and_proceed decision" do
    seed_policy!("system.module_critical_upgrade_ready", "notify_and_proceed")
    module_id = SecureRandom.uuid

    result = service.gate_action!(
      "system.module_critical_upgrade_ready",
      metadata: { "cve_ids" => [ "CVE-2026-99004", "CVE-2026-99005" ], "node_module_id" => module_id },
      reasoning: { summary: "Critical upgrade ready for 2 CVEs" }
    )

    expect(result[:gate]).to eq("notify_and_proceed")

    # The literal, not the fleet constant: a drifted wire value would leave
    # every reader keyed on the fleet kind blind to the CVE lane.
    event = System::FleetEvent.find_by(account_id: account.id, kind: "autonomy.notified")
    expect(event).to be_present,
                     "expected notify_and_proceed to leave a durable FleetEvent, not just a log line"
    expect(event.kind).to eq(System::Fleet::FleetAutonomyService::NOTIFY_EVENT_KIND)
    expect(event.severity).to eq("medium")
    expect(event.source).to eq("cve_responder")
    expect(event.payload["action_category"]).to eq("system.module_critical_upgrade_ready")
    expect(event.payload["gate"]).to eq("notify_and_proceed")
    expect(event.payload["summary"]).to eq("Critical upgrade ready for 2 CVEs")
    expect(event.payload["cve_ids"]).to eq([ "CVE-2026-99004", "CVE-2026-99005" ])
    expect(event.payload["agent_id"]).to eq(agent.id)
    # This lane names the module `node_module_id` (the column name) rather than
    # the `module_id` the payload-derived mapping reads — it must still land on
    # the ref column so the event is filterable per module.
    expect(event.node_module_id).to eq(module_id)
    expect(event.correlation_id).to be_present
  end

  # system_inspect_correlation walks by correlation_id and
  # EventBroadcaster#emit_decision! keys its decision events off the signal
  # fingerprint (DecisionEngine#skill_metadata_payload stamps it as
  # "cve_pub:<cve_id>" for the CVE sensors). A freshly minted id would file the
  # notification in a chain of its own.
  it "correlates the notification with the CVE signal's own decision chain" do
    seed_policy!("system.cve_remediate", "notify_and_proceed")

    service.gate_action!(
      "system.cve_remediate",
      metadata: {
        "cve_id" => "CVE-2026-99010", "signal_kind" => "security.cve_critical_published",
        "signal_fingerprint" => "cve_pub:CVE-2026-99010"
      },
      reasoning: { summary: "critical CVE published" }
    )

    event = System::FleetEvent.find_by(account_id: account.id, kind: "autonomy.notified")
    expect(event).to be_present
    expect(event.correlation_id).to eq("cve_pub:CVE-2026-99010")
    expect(event.payload["signal_kind"]).to eq("security.cve_critical_published")
    # The CVE identifier is a string ("CVE-…"), not the UUID the ref column
    # holds — it must ride in the payload, and must not sink the persist.
    expect(event.payload["cve_id"]).to eq("CVE-2026-99010")
  end

  # Mutation oracle for the emit's PLACEMENT: an unconditional emit inside
  # gate_action! would also fire here, and the examples above could not tell.
  it "does not emit the notify event for an auto_approve decision" do
    seed_policy!("system.cve_remediate", "auto_approve")

    service.gate_action!("system.cve_remediate", metadata: { "cve_id" => "CVE-2026-99011" },
                                                 reasoning: { summary: "auto" })

    expect(System::FleetEvent.where(account_id: account.id, kind: "autonomy.notified")).to be_empty
  end

  it "broadcasts the notify event on the account's fleet channel" do
    seed_policy!("system.cve_remediate", "notify_and_proceed")
    # The proceed half broadcasts its own cve_responder.inline_dispatch event;
    # let that through and pin only the notify broadcast.
    allow(ActionCable.server).to receive(:broadcast)
    expect(ActionCable.server).to receive(:broadcast)
      .with("system_fleet:#{account.id}", hash_including(kind: "autonomy.notified"))

    service.gate_action!("system.cve_remediate", metadata: { "cve_id" => "CVE-2026-99012" },
                                                 reasoning: { summary: "critical" })
  end

  it "keeps the log line alongside the durable record" do
    seed_policy!("system.cve_remediate", "notify_and_proceed")
    allow(Rails.logger).to receive(:info).and_call_original
    expect(Rails.logger).to receive(:info).with(a_string_matching(/\[CveResponder\] Auto-execute: system\.cve_remediate/))
      .and_call_original

    service.gate_action!("system.cve_remediate", metadata: { "cve_id" => "CVE-2026-99013" },
                                                 reasoning: { summary: "critical" })
  end
end
