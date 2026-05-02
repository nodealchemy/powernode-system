# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M7.C — DecisionEngine routes signals to skills + actions.
RSpec.describe System::Fleet::DecisionEngine do
  let(:account)  { create(:account) }
  let(:agent)    { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service)  { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
  let(:engine)   { described_class.new(autonomy_service: service) }

  describe "#decide" do
    context "with an unrecognized signal kind" do
      it "skips with reason" do
        d = engine.decide(kind: "system.unknown_thing", severity: :low, payload: {}, fingerprint: "x")
        expect(d[:decision]).to eq(:skipped)
        expect(d[:reason]).to match(/no binding/)
      end
    end

    context "with a system.cert_expiring signal (no skill, just gate)" do
      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.cert_rotate",
                                       policy: "auto_approve", is_active: true)
      end

      it "routes to system.cert_rotate and proceeds via auto_approve" do
        d = engine.decide(kind: "system.cert_expiring", severity: :medium,
                          payload: { certificate_id: "c-1", instance_id: "i-1" },
                          fingerprint: "cert_expiring:c-1")
        expect(d[:action_category]).to eq("system.cert_rotate")
        expect(d[:decision]).to eq(:proceed)
        expect(d[:gate]).to eq("auto_approve")
      end
    end

    context "with a system.instance_silent signal (skill-driven)" do
      let(:platform) { create(:system_node_platform, account: account) }
      let(:template) { create(:system_node_template, account: account, node_platform: platform) }
      let(:node)     { create(:system_node, account: account, node_template: template) }
      let!(:instance) { create(:system_node_instance, :running, node: node) }

      let!(:chain) do
        create(:ai_approval_chain, account: account,
               trigger_type: "autonomy_action", name: "Fleet Autonomy Actions")
      end

      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.instance_reprovision",
                                       policy: "require_approval", is_active: true)
      end

      it "invokes the drift_remediate skill and gates as require_approval" do
        d = engine.decide(kind: "system.instance_silent", severity: :high,
                          payload: { "instance_id" => instance.id },
                          fingerprint: "instance_silent:#{instance.id}")
        expect(d[:action_category]).to eq("system.instance_reprovision")
        expect(d[:skill_result]).to be_present
        expect(d[:skill_result][:success]).to be true
        expect(d[:decision]).to eq(:pending)
        expect(d[:gate]).to eq("require_approval")
      end
    end
  end

  describe "#decide_all" do
    it "returns one decision per signal" do
      signals = [
        { kind: "system.unknown1", severity: :low, payload: {}, fingerprint: "x" },
        { kind: "system.unknown2", severity: :low, payload: {}, fingerprint: "y" }
      ]
      decisions = engine.decide_all(signals)
      expect(decisions.size).to eq(2)
      expect(decisions.map { |d| d[:decision] }).to all(eq(:skipped))
    end
  end
end
