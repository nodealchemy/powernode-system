# frozen_string_literal: true

require "rails_helper"

# IMP-57e9a90598ee — the operator-declared writer for
# NodeInstance#network_profile.
#
# Until this, the column had ZERO production writers (only smoke-test seeds
# assigned it), so every instance sat at the "lightweight" default forever and
# both OVN serving gates (TopologyCompiler.ovn_control_for / .ovn_nb_plan_for)
# were closed fleet-wide regardless of deployment state. The
# KubernetesClusterProvisionerService error path even instructs operators to
# "promote the NodeInstance to network_profile=heavyweight" — an instruction
# with no tool behind it, until now.
RSpec.describe Ai::Tools::SystemFleetTool, "system_update_instance network_profile" do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "running") }
  let(:tool)          { described_class.new(account: account, internal: true) }

  def call(**rest)
    tool.execute(params: { action: "system_update_instance", instance_id: instance.id }.merge(rest))
  end

  it "promotes an instance to heavyweight and stamps operator provenance" do
    result = call(network_profile: "heavyweight")

    expect(result[:success]).to be(true)
    instance.reload
    expect(instance.network_profile).to eq("heavyweight")
    expect(instance.config["network_profile_source"]).to eq("operator")
  end

  it "demotes back to lightweight — an explicit operator declaration may go both ways" do
    instance.update_columns(network_profile: "heavyweight")

    result = call(network_profile: "lightweight")

    expect(result[:success]).to be(true)
    expect(instance.reload.network_profile).to eq("lightweight")
  end

  it "rejects a value outside the CHECK constraint's set" do
    result = call(network_profile: "colossal")

    expect(result[:success]).to be(false)
    expect(instance.reload.network_profile).to eq("lightweight")
  end

  it "leaves the profile alone when the param is absent" do
    result = call(name: "renamed")

    expect(result[:success]).to be(true)
    instance.reload
    expect(instance.network_profile).to eq("lightweight")
    expect(instance.config["network_profile_source"]).to be_nil
  end

  it "a config replace without the stamp cannot erase an operator declaration" do
    # config REPLACES the stored hash — but the provenance stamp is not
    # config. Wiping it would re-arm auto-classification over an explicit
    # operator choice.
    call(network_profile: "heavyweight")

    result = call(config: { "foo" => "bar" })

    expect(result[:success]).to be(true)
    instance.reload
    expect(instance.config["foo"]).to eq("bar")
    expect(instance.config["network_profile_source"]).to eq("operator")
  end

  it "a config replace that explicitly sets the stamp wins" do
    call(network_profile: "heavyweight")

    result = call(config: { "network_profile_source" => "suggested_first_heartbeat" })

    expect(result[:success]).to be(true)
    expect(instance.reload.config["network_profile_source"]).to eq("suggested_first_heartbeat")
  end

  it "documents the parameter in the action definition" do
    params = described_class.action_definitions.fetch("system_update_instance")[:parameters]
    expect(params).to have_key(:network_profile)
  end
end
