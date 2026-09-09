# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 4 — the extension answers core's
# blast_radius_estimator seam and reads an explicit environment / packed
# tool_params.
RSpec.describe System::EnvironmentResolver, "blast radius and explicit environment" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:ops)      { account.environments.find_by!(slug: "ops") }
  let(:template) { create(:system_node_template, account: account, node_platform: platform, environment: ops) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let!(:instance) { create(:system_node_instance, node: node, status: "running") }

  it "is registered as the core blast_radius_estimator provider" do
    expect(Powernode::ExtensionRegistry.provider(:blast_radius_estimator)).to eq(System::EnvironmentResolver::BlastRadius)
    expect(Ai::EnvironmentResolution.blast_radius(account: account, params: { instance_id: instance.id })).to eq(1)
  end

  it "counts live instances under an instance, node, template, batch and pool; terminated rows do not count" do
    other = create(:system_node_instance, node: node, status: "terminated")
    expect(described_class.blast_radius(account: account, params: { instance_id: instance.id })).to eq(1)
    expect(described_class.blast_radius(account: account, params: { instance_id: other.id })).to eq(0)
    expect(described_class.blast_radius(account: account, params: { node_id: node.id })).to eq(1)
    expect(described_class.blast_radius(account: account, params: { template_id: template.id })).to eq(1)
    expect(described_class.blast_radius(account: account, params: { instance_ids: [ instance.id, other.id ] })).to eq(1)
    expect(described_class.blast_radius(account: account, params: {})).to be_nil
    expect(described_class.blast_radius(account: create(:account), params: { instance_id: instance.id })).to eq(0)
  end

  it "counts, for a module named with an environment, that plane's live instances carrying the module" do
    category = create(:system_node_module_category, account: account)
    mod = create(:system_node_module, account: account, node_platform: platform, category: category)
    System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
    staging = account.environments.find_by!(slug: "staging")
    staging_template = create(:system_node_template, account: account, node_platform: platform, environment: staging)
    System::TemplateModule.create!(node_template: staging_template, node_module: mod)
    2.times { create(:system_node_instance, node: create(:system_node, account: account, node_template: staging_template), status: "running") }
    create(:system_node_instance, node: create(:system_node, account: account, node_template: staging_template), status: "terminated")

    expect(described_class.blast_radius(account: account, params: { module_id: mod.id, environment: "staging" })).to eq(2)
    expect(described_class.blast_radius(account: account, params: { module_id: mod.id, environment: "ops" })).to eq(1)
    expect(described_class.blast_radius(account: account, params: { module_id: mod.id })).to eq(3)
    expect(described_class.blast_radius(account: account, params: { module_id: mod.id, environment: "nowhere" })).to eq(0)
  end

  it "treats an explicit environment as a FLOOR (strictest of named and subject planes) and looks through packed tool_params" do
    expect(described_class.call(account: account, params: { environment: "prod" }).slug).to eq("prod")
    expect(described_class.call(account: account, params: { "environment_id" => ops.id })).to eq(ops)
    # a laxer named plane cannot re-home an ops instance; a stricter one escalates it
    expect(described_class.call(account: account, params: { environment: "staging", instance_id: instance.id })).to eq(ops)
    expect(described_class.call(account: account, params: { environment: "dev", instance_id: instance.id })).to eq(ops)
    expect(described_class.call(account: account, params: { environment: "prod", instance_id: instance.id }).slug).to eq("prod")
    expect(described_class.call(account: account, params: { tool_params: { instance_id: instance.id } })).to eq(ops)
    expect(described_class.blast_radius(account: account, params: { "tool_params" => { "node_id" => node.id } })).to eq(1)
    expect { described_class.call(account: account, params: { environment: "nowhere" }) }
      .to raise_error(Ai::EnvironmentResolution::ResolverError)
  end
end
