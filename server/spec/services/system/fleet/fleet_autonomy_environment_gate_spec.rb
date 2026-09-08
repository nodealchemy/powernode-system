# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 3 — the fleet actuator gate resolves the
# plane its signal acts on and escalates through the same overlay as
# Ai::AutonomyGate. Before this, a `system.instance_reboot` auto_approve row
# rebooted a control-plane instance with no plane check at all: the overlay
# lived only in the gate the DecisionEngine's own appliers never reach.
RSpec.describe System::Fleet::FleetAutonomyService, "environment overlay" do
  let(:account)  { create(:account) }
  let(:agent)    { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service)  { described_class.new(account: account, agent: agent) }
  let(:platform) { create(:system_node_platform, account: account) }
  # ops: protected + monitored, so only DESTRUCTIVE categories park there.
  let(:ops)      { account.environments.find_by!(slug: "ops") }
  let(:ops_instance) do
    create(:system_node_instance,
           node: create(:system_node, account: account,
                        node_template: create(:system_node_template, account: account, node_platform: platform, environment: ops)))
  end
  let(:dev_instance) do
    create(:system_node_instance,
           node: create(:system_node, account: account,
                        node_template: create(:system_node_template, account: account, node_platform: platform)))
  end

  before do
    # The parked arm mints into the agent's approval chain; without one the
    # gate still answers :pending but has no request to hand back.
    create(:ai_approval_chain, account: account, trigger_type: "autonomy_action", name: "Fleet Autonomy Actions")
    Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                   action_category: "system.instance_reboot",
                                   policy: "auto_approve", is_active: true)
  end

  it "parks a destructive auto_approve action against a control-plane instance and names the plane" do
    result = service.gate_action!("system.instance_reboot", metadata: { "instance_id" => ops_instance.id },
                                                            reasoning: { summary: "reboot" })

    expect(result[:decision]).to eq(:pending)
    expect(result[:gate]).to eq("require_approval")
    request = result[:decision_record]
    expect(request).to be_a(Ai::ApprovalRequest)
    expect(request.request_data.to_s).to include("ops").and include("destructive")
  end

  it "reads the instance id from a nested payload too" do
    result = service.gate_action!("system.instance_reboot", metadata: { "payload" => { "instance_id" => ops_instance.id } })

    expect(result[:decision]).to eq(:pending)
    expect(result[:gate]).to eq("require_approval")
  end

  it "lets the same action proceed in dev" do
    result = service.gate_action!("system.instance_reboot", metadata: { "instance_id" => dev_instance.id })

    expect(result[:decision]).to eq(:proceed)
    expect(result[:gate]).to eq("auto_approve")
  end

  it "applies the plane to a decision-engine force_policy override as well" do
    result = service.gate_action!("system.instance_reboot", metadata: { "instance_id" => ops_instance.id },
                                                            force_policy: "auto_approve")

    expect(result[:decision]).to eq(:pending)
    expect(result[:gate]).to eq("require_approval")
  end

  it "resolves #policy_for (the DecisionEngine's pre-invoke verdict) in the same plane" do
    expect(service.policy_for("system.instance_reboot", metadata: { "instance_id" => ops_instance.id })[:policy]).to eq("require_approval")
    expect(service.policy_for("system.instance_reboot", metadata: { "instance_id" => dev_instance.id })[:policy]).to eq("auto_approve")
    expect(service.policy_for("system.instance_reboot")[:policy]).to eq("auto_approve")
  end

  it "fails CLOSED when the resolver itself fails: parks rather than treating the plane as unknown" do
    allow(::Ai::EnvironmentResolution).to receive(:resolve)
      .and_raise(::Ai::EnvironmentResolution::ResolverError, "resolver exploded")

    result = service.gate_action!("system.instance_reboot", metadata: { "instance_id" => dev_instance.id })

    expect(result[:decision]).to eq(:pending)
    expect(result[:gate]).to eq("require_approval")
    expect(result[:decision_record].request_data.to_s).to include("resolver exploded")
  end
end
