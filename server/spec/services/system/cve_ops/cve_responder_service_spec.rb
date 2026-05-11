# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::CveOps::CveResponderService do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account) }
  let(:provider) { create(:ai_provider) }
  let!(:agent) do
    Ai::Agent.create!(
      account: account, creator: user, provider: provider,
      name: "CVE Responder", agent_type: "monitor", status: "active",
      autonomy_config: { "interval_seconds" => 60, "extension" => "system", "scope" => "cve" }
    )
  end
  let!(:approval_chain) do
    Ai::ApprovalChain.create!(
      account: account, name: "CVE Responder Actions",
      trigger_type: "autonomy_action", status: "active", is_sequential: true,
      timeout_action: "reject", timeout_hours: 8,
      steps: [{ "name" => "Sec Op", "approvers" => ["*"], "required_approvals" => 1 }]
    )
  end

  before do
    %w[system.cve_remediate system.cve_auto_remediate system.module_critical_upgrade_ready].each_with_index do |action, i|
      Ai::InterventionPolicy.create!(
        account: account, action_category: action,
        scope: "agent", ai_agent_id: agent.id,
        policy: i == 1 ? "block" : "require_approval",
        priority: 10, is_active: true,
        conditions: {}, preferred_channels: %w[notification]
      )
    end
  end

  describe ".tick!" do
    it "returns ok=false when the CVE Responder agent is not seeded" do
      # Rename out of the way rather than destroy — agent has FK refs from
      # intervention policies and trust score, and Ai::Agent doesn't cascade.
      agent.update!(name: "Some Other Agent")
      r = described_class.tick!(account: account)
      expect(r[:ok]).to be false
      expect(r[:reason]).to match(/not seeded/)
    end

    it "runs a clean tick with no signals" do
      r = described_class.tick!(account: account)
      expect(r[:ok]).to be true
      expect(r[:signal_count]).to eq(0)
      expect(r[:decision_count]).to eq(0)
    end
  end

  describe "#gate_action!" do
    let(:service) { described_class.new(account: account, agent: agent) }

    it "blocks unknown actions" do
      r = service.gate_action!("not_in_policies")
      expect(r[:decision]).to eq(:blocked)
      expect(r[:reason]).to eq("not_permitted")
    end

    it "blocks system.cve_auto_remediate by default (kill-switch)" do
      r = service.gate_action!("system.cve_auto_remediate", metadata: { "cve_id" => "CVE-2026-99001" })
      expect(r[:decision]).to eq(:blocked)
      expect(r[:gate]).to eq("block")
    end

    it "creates a pending approval for system.cve_remediate" do
      r = service.gate_action!(
        "system.cve_remediate",
        metadata: { "cve_id" => "CVE-2026-99002" },
        reasoning: { summary: "Critical OpenSSL" }
      )
      expect(r[:decision]).to eq(:pending)
      expect(r[:gate]).to eq("require_approval")
      expect(r[:decision_record]).to be_a(Ai::ApprovalRequest)
      expect(r[:decision_record].source_type).to eq("system_cve_responder")
    end

    it "deduplicates approval requests by cve_id" do
      2.times do
        service.gate_action!(
          "system.cve_remediate",
          metadata: { "cve_id" => "CVE-2026-99003" },
          reasoning: { summary: "Dup test" }
        )
      end
      pending = Ai::ApprovalRequest.where(account: account, source_type: "system_cve_responder", status: "pending")
      expect(pending.count).to eq(1)
    end

    context "system.module_critical_upgrade_ready (notify_and_proceed, cve_ids plural payload)" do
      before do
        # Flip the policy to notify_and_proceed for this scenario — matches
        # the production seed for module_critical_upgrade_ready.
        Ai::InterventionPolicy.where(
          account: account, ai_agent_id: agent.id,
          action_category: "system.module_critical_upgrade_ready"
        ).update_all(policy: "notify_and_proceed")
      end

      it "extracts cve_id from cve_ids (plural) and dispatches the orchestrator inline" do
        orchestrator = instance_double(::System::Ai::Skills::CveRemediationOrchestrationExecutor)
        allow(::System::Ai::Skills::CveRemediationOrchestrationExecutor).to receive(:new).and_return(orchestrator)
        allow(orchestrator).to receive(:execute).and_return({ success: true, data: { refresh_dispatches: [], rolling_upgrade_plans: [], exposures_remediating: 0 } })

        result = service.gate_action!(
          "system.module_critical_upgrade_ready",
          metadata: {
            "cve_ids" => ["CVE-2026-99004", "CVE-2026-99005"],
            "node_module_id" => "test-module-id",
            "affected_module_ids" => ["test-module-id"]
          },
          reasoning: { summary: "Critical upgrade ready" }
        )

        expect(result[:decision]).to eq(:proceed)
        expect(result[:gate]).to eq("notify_and_proceed")
        # Both CVEs should drive separate orchestrator calls — proves the
        # bug where dispatch_inline bailed on missing singular cve_id is gone.
        expect(orchestrator).to have_received(:execute).with(hash_including(cve_id: "CVE-2026-99004"))
        expect(orchestrator).to have_received(:execute).with(hash_including(cve_id: "CVE-2026-99005"))
      end

      it "still works with singular cve_id payload for forward compatibility" do
        orchestrator = instance_double(::System::Ai::Skills::CveRemediationOrchestrationExecutor)
        allow(::System::Ai::Skills::CveRemediationOrchestrationExecutor).to receive(:new).and_return(orchestrator)
        allow(orchestrator).to receive(:execute).and_return({ success: true, data: {} })

        service.gate_action!(
          "system.module_critical_upgrade_ready",
          metadata: { "cve_id" => "CVE-2026-99006" },
          reasoning: { summary: "Single CVE shape" }
        )
        expect(orchestrator).to have_received(:execute).with(hash_including(cve_id: "CVE-2026-99006"))
      end
    end
  end

  describe "#collect_signals" do
    it "returns an array even when no CVE/CveExposure rows exist" do
      service = described_class.new(account: account, agent: agent)
      expect(service.collect_signals).to eq([])
    end
  end
end
