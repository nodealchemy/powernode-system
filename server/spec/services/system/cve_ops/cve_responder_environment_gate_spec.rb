# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 3 — the CVE gate is the OTHER fleet actuator
# gate (see fleet_autonomy_environment_gate_spec.rb); it takes the same
# overlay, so a plane that requires approval for the CVE family parks the
# remediation instead of dispatching it inline.
RSpec.describe System::CveOps::CveResponderService, "environment overlay" do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account) }
  let(:provider) { create(:ai_provider) }
  let(:agent) do
    Ai::Agent.create!(account: account, creator: user, provider: provider,
                      name: "CVE Responder", agent_type: "monitor", status: "active")
  end
  let(:service)  { described_class.new(account: account, agent: agent) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:ops)      { account.environments.find_by!(slug: "ops") }
  let(:ops_instance) do
    create(:system_node_instance,
           node: create(:system_node, account: account,
                        node_template: create(:system_node_template, account: account, node_platform: platform, environment: ops)))
  end

  before do
    create(:ai_approval_chain, account: account, trigger_type: "autonomy_action", name: "CVE Responder Actions")
    ::Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.cve_remediate", policy: "auto_approve", is_active: true)
    orchestrator = instance_double(::System::Ai::Skills::CveRemediationOrchestrationExecutor)
    allow(::System::Ai::Skills::CveRemediationOrchestrationExecutor).to receive(:new).and_return(orchestrator)
    allow(orchestrator).to receive(:execute).and_return({ success: true, data: {} })
  end

  it "parks an auto_approve remediation when the instance's plane requires approval for the family" do
    ops.update!(approval_required_categories: [ "system.cve_*" ])

    result = service.gate_action!("system.cve_remediate",
                                  metadata: { "cve_id" => "CVE-2026-1", "instance_id" => ops_instance.id })

    expect(result[:decision]).to eq(:pending)
    expect(result[:gate]).to eq("require_approval")
    expect(::System::Ai::Skills::CveRemediationOrchestrationExecutor).not_to have_received(:new)
  end

  it "dispatches inline when no plane rule fires" do
    result = service.gate_action!("system.cve_remediate",
                                  metadata: { "cve_id" => "CVE-2026-1", "instance_id" => ops_instance.id })

    expect(result[:decision]).to eq(:proceed)
    expect(::System::Ai::Skills::CveRemediationOrchestrationExecutor).to have_received(:new)
  end

  it "fails CLOSED on a resolver failure" do
    allow(::Ai::EnvironmentResolution).to receive(:resolve)
      .and_raise(::Ai::EnvironmentResolution::ResolverError, "resolver exploded")

    result = service.gate_action!("system.cve_remediate", metadata: { "cve_id" => "CVE-2026-1" })

    expect(result[:decision]).to eq(:pending)
    expect(::System::Ai::Skills::CveRemediationOrchestrationExecutor).not_to have_received(:new)
  end
end
