# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 3 — the executor gate resolves the plane
# from the executor's own inputs, and a NESTED peer refuses a plane
# escalation instead of riding through under its parent's verdict.
RSpec.describe "System::Ai::Skills::BaseSkillExecutor environment gate" do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account) }
  let(:platform) { create(:system_node_platform, account: account) }
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

  let(:reboot_class) do
    Class.new(System::Ai::Skills::BaseSkillExecutor) do
      def self.performed
        @performed ||= []
      end

      skill_descriptor(
        name: "zz_env_reboot_fixture", description: "destructive fixture", category: "fleet",
        requires_approval: true, action_category: "system.instance_reboot",
        inputs: { instance_id: { type: "string", required: true } }, outputs: {}
      )

      protected

      def perform(instance_id:)
        self.class.performed << instance_id
        success(instance_id: instance_id)
      end
    end
  end

  let(:composer_class) do
    Class.new(System::Ai::Skills::BaseSkillExecutor) do
      skill_descriptor(
        name: "zz_env_composer_fixture", description: "nests the reboot", category: "fleet",
        inputs: { instance_id: { type: "string", required: true } }, outputs: {}
      )

      protected

      def perform(instance_id:)
        success(inner: executor(ZzEnvRebootFixtureExecutor).execute(instance_id: instance_id))
      end
    end
  end

  before do
    stub_const("ZzEnvRebootFixtureExecutor", reboot_class)
    stub_const("ZzEnvComposerFixtureExecutor", composer_class)
    Ai::InterventionPolicy.create!(account: account, action_category: "system.instance_reboot",
                                   scope: "action_type", policy: "auto_approve", priority: 10, is_active: true)
  end

  it "runs a destructive auto_approve skill in dev and parks it against the control plane" do
    ok = ZzEnvRebootFixtureExecutor.new(account: account, user: user).execute(instance_id: dev_instance.id)
    expect(ok[:success]).to be true

    parked = ZzEnvRebootFixtureExecutor.new(account: account, user: user).execute(instance_id: ops_instance.id)
    expect(parked[:success]).to be true
    expect(parked.dig(:data, :pending)).to be true
    expect(ZzEnvRebootFixtureExecutor.performed).to eq([ dev_instance.id ])
  end

  it "refuses a NESTED peer whose plane escalates, instead of proceeding under the parent's verdict" do
    result = ZzEnvComposerFixtureExecutor.new(account: account, user: user).execute(instance_id: ops_instance.id)

    expect(ZzEnvRebootFixtureExecutor.performed).to be_empty
    expect(result.dig(:data, :inner, :success)).to be false
    expect(result.dig(:data, :inner, :error)).to match(/ops/).and match(/top-level/)
  end

  it "refuses a NESTED peer when the plane cannot be resolved at all (fail closed)" do
    allow(::Ai::EnvironmentResolution).to receive(:resolve)
      .and_raise(::Ai::EnvironmentResolution::ResolverError, "resolver exploded")

    result = ZzEnvComposerFixtureExecutor.new(account: account, user: user).execute(instance_id: dev_instance.id)

    expect(ZzEnvRebootFixtureExecutor.performed).to be_empty
    expect(result.dig(:data, :inner, :success)).to be false
    expect(result.dig(:data, :inner, :error)).to match(/policy resolution failed/)
  end

  it "still lets a nested peer through in dev" do
    result = ZzEnvComposerFixtureExecutor.new(account: account, user: user).execute(instance_id: dev_instance.id)

    expect(result.dig(:data, :inner, :success)).to be true
    expect(ZzEnvRebootFixtureExecutor.performed).to eq([ dev_instance.id ])
  end
end
