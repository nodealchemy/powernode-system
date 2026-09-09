# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 5 — asking the fleet BY PLANE.
#
# Increment 1 taught every fleet row to report its environment_slug, which made
# a plane readable one row at a time and answerable for the fleet only by
# fetching all of it and grouping client-side. These four verbs take the plane
# as a filter instead, and an unknown plane is REFUSED rather than dropped: a
# filter that silently disappears answers "what is in prod" with the whole
# fleet.
RSpec.describe Ai::Tools::SystemFleetTool, "environment list filters" do
  let(:account)   { create(:account) }
  let!(:operator) do
    create(:user, account: account,
                  permissions: %w[system.nodes.read system.node_instances.read system.templates.read])
  end
  let(:agent) { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Reader") }
  let(:tool)  { described_class.new(account: account, agent: agent, internal: true) }

  let(:dev) { account.environments.find_by!(slug: "dev") }
  let(:ops) { account.environments.find_by!(slug: "ops") }

  # Templates carry the plane; nodes and instances inherit it on create, so
  # each fixture below is built through its template rather than stamped.
  let!(:dev_template) { create(:system_node_template, account: account, environment: dev) }
  let!(:ops_template) { create(:system_node_template, account: account, environment: ops) }
  let!(:dev_node)     { create(:system_node, account: account, node_template: dev_template) }
  let!(:ops_node)     { create(:system_node, account: account, node_template: ops_template) }
  let!(:dev_instance) { create(:system_node_instance, node: dev_node) }
  let!(:ops_instance) { create(:system_node_instance, node: ops_node) }

  def pool!(template, name)
    ::System::InstancePool.create!(
      account: account, name: name, node_template: template,
      target_size: 1, min_size: 0, max_size: 5,
      lifecycle_class: "ephemeral", status: "active"
    )
  end

  let!(:dev_pool) { pool!(dev_template, "dev-pool") }
  let!(:ops_pool) { pool!(ops_template, "ops-pool") }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest).with_indifferent_access)
  end

  it "narrows nodes to one plane and leaves the unfiltered answer whole" do
    filtered = call("system_list_nodes", environment: "ops")
    expect(filtered[:success]).to be true
    expect(filtered.dig(:data, :nodes).map { |n| n[:id] }).to contain_exactly(ops_node.id)
    expect(filtered.dig(:data, :count)).to eq(1)

    expect(call("system_list_nodes").dig(:data, :nodes).map { |n| n[:id] })
      .to contain_exactly(dev_node.id, ops_node.id)
  end

  it "narrows instances to one plane" do
    r = call("system_list_instances", environment: "dev")
    expect(r.dig(:data, :instances).map { |i| i[:id] }).to contain_exactly(dev_instance.id)
    expect(r.dig(:data, :instances).first[:environment_slug]).to eq("dev")
  end

  it "narrows templates to one plane, alongside the name filter" do
    r = call("system_list_templates", environment: "ops")
    expect(r.dig(:data, :templates).map { |t| t[:id] }).to contain_exactly(ops_template.id)
  end

  it "narrows pools to one plane and reports each pool's plane" do
    r = call("system_list_instance_pools", environment: "ops")
    expect(r[:success]).to be true
    pools = r.dig(:data, :pools)
    expect(pools.map { |p| p[:id] }).to contain_exactly(ops_pool.id)
    expect(pools.first[:environment_slug]).to eq("ops")
  end

  it "accepts an environment id as well as a slug" do
    r = call("system_list_nodes", environment: ops.id)
    expect(r.dig(:data, :nodes).map { |n| n[:id] }).to contain_exactly(ops_node.id)
  end

  # The refusal is the point of the increment: an unknown plane must not fall
  # back to the whole fleet on ANY of the four surfaces.
  it "refuses an unknown plane on every list surface instead of ignoring the filter" do
    {
      "system_list_nodes"          => :nodes,
      "system_list_instances"      => :instances,
      "system_list_templates"      => :templates,
      "system_list_instance_pools" => :pools
    }.each do |action, key|
      r = call(action, environment: "no-such-plane")
      expect(r[:success]).to be(false), "#{action} accepted an unknown plane"
      expect(r[:error]).to match(/environment 'no-such-plane' not found in this account/)
      expect(r.dig(:data, key)).to be_nil
    end
  end

  it "refuses another account's plane by id" do
    foreign = create(:account).environments.find_by!(slug: "dev")
    r = call("system_list_nodes", environment: foreign.id)
    expect(r[:success]).to be false
    expect(r[:error]).to match(/not found in this account/)
  end
end
