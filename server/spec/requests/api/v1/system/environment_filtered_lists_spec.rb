# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 5, REST half — the same plane filter the MCP
# list verbs carry, on the three fleet-WIDE list surfaces.
#
# node_instances is deliberately absent: its index is nested under a node
# (config/routes.rb — a flat resource would 404 because set_node always runs),
# and a node has ONE plane which it cascades to its instances, so a plane
# filter there could only ever confirm what the path already fixed.
RSpec.describe "fleet list surfaces filtered by environment", type: :request do
  let(:account) { create(:account) }
  let(:reader) do
    user_with_permissions("system.nodes.read", "system.templates.read",
                          "system.node_instances.read", account: account)
  end

  let(:dev) { account.environments.find_by!(slug: "dev") }
  let(:ops) { account.environments.find_by!(slug: "ops") }

  let!(:dev_template) { create(:system_node_template, account: account, environment: dev) }
  let!(:ops_template) { create(:system_node_template, account: account, environment: ops) }
  let!(:dev_node)     { create(:system_node, account: account, node_template: dev_template) }
  let!(:ops_node)     { create(:system_node, account: account, node_template: ops_template) }

  def pool!(template, name)
    ::System::InstancePool.create!(
      account: account, name: name, node_template: template,
      target_size: 1, min_size: 0, max_size: 5,
      lifecycle_class: "ephemeral", status: "active"
    )
  end

  let!(:dev_pool) { pool!(dev_template, "dev-pool") }
  let!(:ops_pool) { pool!(ops_template, "ops-pool") }

  it "narrows nodes to the named plane" do
    get "/api/v1/system/nodes", params: { environment: "ops" }, headers: auth_headers_for(reader)
    expect(response).to have_http_status(:ok)
    expect(json_response_data["nodes"].map { |n| n["id"] }).to contain_exactly(ops_node.id)
  end

  # Named by ID here, not slug — both spellings resolve, and the account's own
  # seeded templates live in dev, so `ops` is the plane with an exact answer.
  it "narrows templates to the named plane" do
    get "/api/v1/system/node_templates", params: { environment: ops.id }, headers: auth_headers_for(reader)
    expect(response).to have_http_status(:ok)
    expect(json_response_data["node_templates"].map { |t| t["id"] }).to contain_exactly(ops_template.id)

    get "/api/v1/system/node_templates", params: { environment: "dev" }, headers: auth_headers_for(reader)
    ids = json_response_data["node_templates"].map { |t| t["id"] }
    expect(ids).to include(dev_template.id)
    expect(ids).not_to include(ops_template.id)
  end

  it "narrows pools to the named plane and reports each pool's plane" do
    get "/api/v1/system/instance_pools", params: { environment: "ops" }, headers: auth_headers_for(reader)
    expect(response).to have_http_status(:ok)
    pools = json_response_data["pools"]
    expect(pools.map { |p| p["id"] }).to contain_exactly(ops_pool.id)
    expect(pools.first["environment_slug"]).to eq("ops")
  end

  # FAIL CLOSED, and specifically BEFORE the query: the before_action halts, so
  # the response carries the refusal and no rows at all.
  it "404s an unknown plane on every surface rather than answering for the whole fleet" do
    {
      "/api/v1/system/nodes"          => "nodes",
      "/api/v1/system/node_templates" => "node_templates",
      "/api/v1/system/instance_pools" => "pools"
    }.each do |path, key|
      get path, params: { environment: "no-such-plane" }, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:not_found), "#{path} accepted an unknown plane"
      body = JSON.parse(response.body)
      expect(body["error"]).to match(/environment 'no-such-plane' not found in this account/)
      expect(body["data"]).to be_nil
      expect(body.dig("data", key)).to be_nil
    end
  end

  it "refuses another account's plane" do
    foreign = create(:account).environments.find_by!(slug: "ops")
    get "/api/v1/system/nodes", params: { environment: foreign.id }, headers: auth_headers_for(reader)
    expect(response).to have_http_status(:not_found)
  end

  it "answers for every plane when no plane is named" do
    get "/api/v1/system/nodes", headers: auth_headers_for(reader)
    expect(json_response_data["nodes"].map { |n| n["id"] })
      .to contain_exactly(dev_node.id, ops_node.id)
  end
end
