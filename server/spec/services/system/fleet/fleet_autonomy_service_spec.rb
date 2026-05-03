# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M7.A — FleetAutonomyService.
RSpec.describe System::Fleet::FleetAutonomyService do
  let(:account)  { create(:account) }
  let(:agent)    { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service)  { described_class.new(account: account, agent: agent) }

  describe "#permitted_actions" do
    it "returns the list of action_categories from active InterventionPolicy rows for this agent" do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.cert_rotate",
                                     policy: "auto_approve", is_active: true)
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.instance_reprovision",
                                     policy: "require_approval", is_active: true)
      expect(service.permitted_actions).to contain_exactly(
        "system.cert_rotate",
        "system.instance_reprovision"
      )
    end
  end

  describe ".all_fleet_actions" do
    it "returns only system.* actions across the account" do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.cert_rotate",
                                     policy: "auto_approve", is_active: true)
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "trading.create_session",
                                     policy: "require_approval", is_active: true)
      expect(described_class.all_fleet_actions(account)).to eq([ "system.cert_rotate" ])
    end
  end

  describe "#gate_action!" do
    context "with an action not in the agent's policies" do
      it "blocks with reason :not_permitted" do
        result = service.gate_action!("system.cert_rotate")
        expect(result[:decision]).to eq(:blocked)
        expect(result[:reason]).to eq("not_permitted")
      end
    end

    context "with auto_approve policy" do
      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.cert_rotate",
                                       policy: "auto_approve", is_active: true)
      end

      it "returns proceed without creating an ApprovalRequest" do
        expect {
          result = service.gate_action!("system.cert_rotate")
          expect(result[:decision]).to eq(:proceed)
          expect(result[:gate]).to eq("auto_approve")
        }.not_to change(Ai::ApprovalRequest, :count)
      end
    end

    context "with notify_and_proceed policy" do
      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.module_assign",
                                       policy: "notify_and_proceed", is_active: true)
      end

      it "returns proceed and logs the action" do
        result = service.gate_action!("system.module_assign", reasoning: { summary: "drift" })
        expect(result[:decision]).to eq(:proceed)
        expect(result[:gate]).to eq("notify_and_proceed")
      end
    end

    context "with require_approval policy" do
      let!(:chain) do
        create(:ai_approval_chain, account: account,
               trigger_type: "autonomy_action", name: "Fleet Autonomy Actions")
      end

      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.instance_reprovision",
                                       policy: "require_approval", is_active: true)
      end

      it "creates a pending ApprovalRequest with source_type=system_fleet" do
        expect {
          result = service.gate_action!("system.instance_reprovision",
                                        metadata: { instance_id: "inst-1" },
                                        reasoning: { summary: "instance silent" })
          expect(result[:decision]).to eq(:pending)
          expect(result[:gate]).to eq("require_approval")
          expect(result[:decision_record]).to be_present
        }.to change(Ai::ApprovalRequest, :count).by(1)

        req = Ai::ApprovalRequest.last
        expect(req.source_type).to eq("system_fleet")
        expect(req.request_data["action_category"]).to eq("system.instance_reprovision")
        expect(req.request_data["payload"]).to eq("instance_id" => "inst-1")
      end

      it "dedups concurrent requests for the same instance + action" do
        service.gate_action!("system.instance_reprovision",
                             metadata: { instance_id: "inst-1" },
                             reasoning: { summary: "first" })
        expect {
          service.gate_action!("system.instance_reprovision",
                               metadata: { instance_id: "inst-1" },
                               reasoning: { summary: "second" })
        }.not_to change(Ai::ApprovalRequest, :count)

        # The dedup branch updates the existing request rather than creating new
        req = Ai::ApprovalRequest.last
        expect(req.description).to eq("second")
      end
    end
  end

  describe "ADVANCEMENT_ACTIONS" do
    it "covers fleet-advancement classes (4h TTL bucket)" do
      expect(described_class::ADVANCEMENT_ACTIONS).to include(
        "system.module_promote_to_live",
        "system.fleet_rolling_upgrade",
        "system.region_expansion"
      )
    end
  end
end
