# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 3 — the extension answers core's
# environment_resolver seam, and the gate escalates through it end to end.
RSpec.describe System::EnvironmentResolver do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  # ops: protected but monitored, so only DESTRUCTIVE categories park there
  # (prod is seeded supervised and parks everything).
  let(:ops)      { account.environments.find_by!(slug: "ops") }
  let(:template) { create(:system_node_template, account: account, node_platform: platform, environment: ops) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, node: node) }

  it "is registered as the core seam's provider" do
    expect(Powernode::ExtensionRegistry.provider(:environment_resolver)).to eq(described_class)
  end

  it "resolves instance, node, template and pool params under the account scope" do
    pool = System::InstancePool.create!(account: account, node_template: template, name: "p", lifecycle_class: "ephemeral",
                                        status: "active", target_size: 0, min_size: 0, max_size: 1)
    expect(described_class.call(account: account, params: { instance_id: instance.id })).to eq(ops)
    expect(described_class.call(account: account, params: { "node_id" => node.id })).to eq(ops)
    expect(described_class.call(account: account, params: { template_id: template.id })).to eq(ops)
    expect(described_class.call(account: account, params: { instance_pool_id: pool.id })).to eq(ops)
    expect(described_class.call(account: account, params: {})).to be_nil
    expect(described_class.call(account: account, params: { instance_id: "not-a-uuid" })).to be_nil
    expect(described_class.call(account: create(:account), params: { instance_id: instance.id })).to be_nil
  end

  it "places a plural batch and a task's polymorphic subject in the strictest plane they touch" do
    dev_instance = create(:system_node_instance, node: create(:system_node, account: account,
                                                              node_template: create(:system_node_template, account: account, node_platform: platform)))
    expect(described_class.call(account: account, params: { instance_ids: [ dev_instance.id ] }).slug).to eq("dev")
    expect(described_class.call(account: account, params: { instance_ids: [ dev_instance.id, instance.id ] })).to eq(ops)
    expect(described_class.call(account: account, params: { "node_ids" => [ node.id ] })).to eq(ops)
    expect(described_class.call(account: account, params: { instance_ids: [] })).to be_nil
    expect(described_class.call(account: account,
                                params: { task_attributes: { operable_type: "System::NodeInstance", operable_id: instance.id } })).to eq(ops)
    expect(described_class.call(account: account,
                                params: { task_attributes: { "operable_type" => "System::Node", "operable_id" => node.id } })).to eq(ops)
    expect(described_class.call(account: account,
                                params: { task_attributes: { operable_type: "System::Volume", operable_id: node.id } })).to be_nil
  end

  it "resolves SDWAN peers and networks through their instances, taking the strictest plane for a network" do
    network = create(:sdwan_network, account: account)
    ops_peer = create(:sdwan_peer, account: account, network: network, node_instance: instance)
    dev_instance = create(:system_node_instance, node: create(:system_node, account: account,
                                                              node_template: create(:system_node_template, account: account, node_platform: platform)))
    create(:sdwan_peer, account: account, network: network, node_instance: dev_instance)

    expect(described_class.call(account: account, params: { peer_id: ops_peer.id })).to eq(ops)
    expect(described_class.call(account: account, params: { network_id: network.id })).to eq(ops)
  end

  describe "through the fleet tool's gated terminate" do
    let(:tool) { Ai::Tools::SystemFleetTool.new(account: account, internal: true) }

    before do
      Ai::InterventionPolicy.register_category!("system.task.terminate")
      Ai::InterventionPolicy.create!(account: account, action_category: "system.task.terminate",
                                      policy: "auto_approve", scope: "global", priority: 5, is_active: true)
      allow(System::Executors::TerminateInstance).to receive(:execute).and_return({ success: true, data: {} })
    end

    it "parks a terminate against a control-plane instance and names the plane, while a dev instance proceeds" do
      r = tool.execute(params: { action: "system_terminate_instance", instance_id: instance.id })
      expect(r[:success]).to be true
      expect(r.dig(:data, :pending)).to be true
      request = Ai::ApprovalRequest.find(r.dig(:data, :approval_request_id))
      expect(request.request_data["environment"]).to include("slug" => "ops", "is_protected" => true)
      expect(request.request_data["environment_escalation"]).to include("protected")

      dev_template = create(:system_node_template, account: account, node_platform: platform)
      dev_instance = create(:system_node_instance, node: create(:system_node, account: account, node_template: dev_template))
      r2 = tool.execute(params: { action: "system_terminate_instance", instance_id: dev_instance.id })
      expect(r2[:success]).to be true
      expect(r2.dig(:data, :pending)).to be_nil
      expect(System::Executors::TerminateInstance).to have_received(:execute).once
    end
  end
end
