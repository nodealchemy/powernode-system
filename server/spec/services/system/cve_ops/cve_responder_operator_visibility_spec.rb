# frozen_string_literal: true

require "rails_helper"

# IMP-60717919d4a0 — two operator-visibility defects on the CVE Responder's
# autonomy lane, both core-mode safe (no Ai::ApprovalChain needed).
#
# 1. AUDIBLE FAILURE. CveRemediationOrchestrationExecutor builds a precise
#    failure message (module, candidate version, legal next promotion rung —
#    IMP-9b8d774298d5) and the sole production caller, #dispatch_single, used
#    to discard it: the log line said `ok=false`, the
#    `cve_responder.inline_dispatch` FleetEvent carried no error field and a
#    hardcoded `severity: :low`, and it carried no correlation_id at all, so it
#    landed in no chain (the notify lane mints a fresh id; this call passed
#    none).
#
# 2. ALARM EXPIRY. An exposure older than the sensor's detection window is
#    invisible to CvePublishedSensor forever; the tick now runs
#    AgedExposureEscalator so it stays reachable as a FleetEvent.
RSpec.describe System::CveOps::CveResponderService, "operator visibility" do
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

  def inline_dispatch_event
    ::System::FleetEvent.find_by(account_id: account.id, kind: "cve_responder.inline_dispatch")
  end

  describe "#dispatch_single audibility" do
    let(:orchestrator) { instance_double(::System::Ai::Skills::CveRemediationOrchestrationExecutor) }

    before do
      seed_policy!("system.cve_remediate", "auto_approve")
      allow(::System::Ai::Skills::CveRemediationOrchestrationExecutor).to receive(:new).and_return(orchestrator)
    end

    it "carries the orchestrator's failure reason on the inline_dispatch event, above the low band" do
      message = "cve remediation dispatched nothing: 1 module has a newer version that is not " \
                "promoted to blessed/live, so no rolling upgrade can be planned. Exposures left open."
      allow(orchestrator).to receive(:execute).and_return({ success: false, error: message })
      allow(Rails.logger).to receive(:info).and_call_original
      expect(Rails.logger).to receive(:info)
        .with(a_string_matching(/\[CveResponder\] inline dispatch cve=CVE-2026-92001 .*ok=false.*dispatched nothing/))
        .and_call_original

      service.gate_action!(
        "system.cve_remediate",
        metadata: { "cve_id" => "CVE-2026-92001", "signal_fingerprint" => "cve_pub:CVE-2026-92001" },
        reasoning: { summary: "critical" }
      )

      event = inline_dispatch_event
      expect(event).to be_present
      expect(event.payload["ok"]).to be false
      expect(event.payload["error"]).to include("dispatched nothing")
      expect(event.severity).to eq("medium")
      expect(event.correlation_id).to eq("cve_pub:CVE-2026-92001")
    end

    it "carries skipped_reason and remediation_dispatched from a success that dispatched nothing" do
      allow(orchestrator).to receive(:execute).and_return(
        { success: true, data: { refresh_dispatches: [], rolling_upgrade_plans: [],
                                 exposures_remediating: 0, remediation_dispatched: false,
                                 skipped_reason: "no_candidate_version" } }
      )

      service.gate_action!("system.cve_remediate", metadata: { "cve_id" => "CVE-2026-92002" },
                                                   reasoning: { summary: "critical" })

      event = inline_dispatch_event
      expect(event.payload["ok"]).to be true
      expect(event.payload["skipped_reason"]).to eq("no_candidate_version")
      expect(event.payload["remediation_dispatched"]).to be false
      expect(event.payload).not_to have_key("error")
      expect(event.severity).to eq("low")
      # No fingerprint on the metadata: falls back to the sensor's own key so
      # the event still lands in the CVE's chain.
      expect(event.correlation_id).to eq("cve_pub:CVE-2026-92002")
    end

    it "bounds and redacts the error text on its way into the persisted payload" do
      secret = "AKIAIOSFODNN7EXAMPLE"
      allow(orchestrator).to receive(:execute)
        .and_return({ success: false, error: "refresh failed key=#{secret} " + ("x" * 2000) })

      service.gate_action!("system.cve_remediate", metadata: { "cve_id" => "CVE-2026-92003" },
                                                   reasoning: { summary: "critical" })

      error = inline_dispatch_event.payload["error"]
      expect(error.length).to be <= ::System::Ai::Skills::BaseSkillExecutor::AUDIT_TEXT_LIMIT
      expect(error).not_to include(secret)
    end
  end

  describe "#tick! aged-out escalation" do
    let(:platform)  { create(:system_node_platform, account: account) }
    let(:category)  { create(:system_node_module_category, account: account) }
    let(:node_module) do
      create(:system_node_module, account: account, node_platform: platform,
             category: category, variety: "subscription", name: "openssl-base")
    end
    let(:node_module_version) do
      create(:system_node_module_version, node_module: node_module, version_number: 1)
    end

    it "keeps an exposure older than the detection window reachable as a FleetEvent" do
      cve = ::System::Cve.create!(
        cve_id: "CVE-2026-92010", severity: "critical",
        affected_packages: [ { "name" => "openssl", "version" => "<3.1.4" } ],
        summary: "aged", feed_source: "TEST", published_at: Time.current
      )
      ::System::CveExposure.create!(
        cve: cve, node_module_version: node_module_version, package_name: "openssl",
        package_version: "3.1.3", state: "open", detected_at: 48.hours.ago
      )

      result = service.tick!

      expect(result[:ok]).to be true
      # The sensor no longer sees it...
      expect(result[:signal_count]).to eq(0)
      # ...and the operator still can.
      expect(result[:aged_out_count]).to eq(1)
      event = ::System::FleetEvent.find_by(account_id: account.id, kind: "cve_responder.exposure_aged_out")
      expect(event).to be_present
      expect(event.correlation_id).to eq("cve_pub:CVE-2026-92010")
      complete = ::System::FleetEvent.find_by(account_id: account.id, kind: "cve_responder.tick_complete")
      expect(complete.payload["aged_out_count"]).to eq(1)
    end

    # IMP-60717919d4a0 (review) — the fresh lane and the aged lane are
    # complements of ONE window. Resolving it twice in a tick lets a config
    # change land between them and open a gap (widened) or an overlap
    # (narrowed) — the hazard CvePublishedSensor#detection_lookback is
    # memoized to prevent, defeated by constructing a second sensor.
    it "resolves the detection window exactly once per tick" do
      expect(::System::CveOps::Sensors::CvePublishedSensor)
        .to receive(:new).once.and_call_original

      service.tick!
    end
  end
end
