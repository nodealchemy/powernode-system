# frozen_string_literal: true

require "rails_helper"

# IMP-9ce0ed39c557 — system.instance.out_of_band_exec's governance shape:
# declared OUTSIDE PolicyDeclarations::POLICY_SETS (like the manual-operations
# set), so it takes no OPERATOR_TWINS pairing — the same reason
# system.task.ssh_command needs none (PolicyDeclarations.owner_of returns nil
# for both; neither has a natural owning agent). Reconciled by
# PolicyReconciler#declared_sets' out_of_band_exec_set, registered for the
# Autonomy panel by the engine's to_prepare block, and named to
# GovernanceGapSensor#declared_categories so it does not read as an orphan.
RSpec.describe "system.instance.out_of_band_exec governance" do
  let(:account) { create(:account) }

  it "matches System::OutOfBandExecService::ACTION_CATEGORY — one string, two declarations" do
    expect(::System::Governance::PolicyDeclarations::OUT_OF_BAND_EXEC_POLICIES.keys)
      .to eq([ ::System::OutOfBandExecService::ACTION_CATEGORY ])
  end

  it "has no owning agent, the same as system.task.ssh_command" do
    expect(::System::Governance::PolicyDeclarations.owner_of(::System::OutOfBandExecService::ACTION_CATEGORY))
      .to be_nil
    expect(::System::Governance::PolicyDeclarations.owner_of("system.task.ssh_command")).to be_nil
  end

  it "is registered for the Autonomy panel" do
    expect(::Ai::InterventionPolicy.registered_categories)
      .to include(::System::OutOfBandExecService::ACTION_CATEGORY)
  end

  it "is not reported by GovernanceGapSensor's category_unowned detector" do
    sensor = ::System::Fleet::Sensors::GovernanceGapSensor.new(account: account)
    subjects = sensor.sense.map { |s| s.payload["subject"] }

    expect(subjects).not_to include(::System::OutOfBandExecService::ACTION_CATEGORY)
  end

  it "PolicyReconciler creates the row at scope global, agent-less, require_approval" do
    result = ::System::Governance::PolicyReconciler.new(account: account).reconcile!

    expect(result.created_categories).to include(
      "out-of-band-exec-operator/#{::System::OutOfBandExecService::ACTION_CATEGORY}"
    )
    policy = ::Ai::InterventionPolicy.find_by(
      account: account, action_category: ::System::OutOfBandExecService::ACTION_CATEGORY
    )
    expect(policy).to be_present
    expect(policy.scope).to eq("global")
    expect(policy.ai_agent_id).to be_nil
    expect(policy.policy).to eq("require_approval")
  end

  it "resolves require_approval for BOTH an operator (agent-less) and an agent caller — scope global is agent-binding by design" do
    ::System::Governance::PolicyReconciler.new(account: account).reconcile!
    agent = create(:ai_agent, account: account)
    service = ::Ai::InterventionPolicyService.new(account: account)

    operator_resolution = service.resolve(action_category: ::System::OutOfBandExecService::ACTION_CATEGORY)
    agent_resolution = service.resolve(action_category: ::System::OutOfBandExecService::ACTION_CATEGORY, agent: agent)

    expect(operator_resolution[:policy]).to eq("require_approval")
    expect(agent_resolution[:policy]).to eq("require_approval")
  end
end
