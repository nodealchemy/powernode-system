# frozen_string_literal: true

require "rails_helper"

# Phase 10.4 backend — searchable scope for the workspace mention picker.
RSpec.describe "GET /api/v1/system/node_instance_peers/searchable", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { user_with_permissions("system.peers.read", account: account) }
  let(:headers) { auth_headers_for(user) }

  let(:node) { create(:system_node, account: account, name: "web-01") }
  let(:other_node) { create(:system_node, account: other_account, name: "foreign-01") }

  def create_peer(handle:, node_instance:, enabled: true, status: "active")
    instance = node_instance
    peer = ::System::AgentPeeringService.announce!(
      node_instance: instance, capabilities: {}, skills: [], addresses: [ "10.0.0.5" ]
    ).peer
    peer.update!(handle: handle, enabled: enabled, status: status)
    peer
  end

  let!(:enabled_peer_a) do
    instance = create(:system_node_instance, node: node, name: "i-aaa")
    create_peer(handle: "instance-aaaaaaaa", node_instance: instance, enabled: true)
  end

  let!(:enabled_peer_b) do
    instance = create(:system_node_instance, node: node, name: "i-bbb")
    create_peer(handle: "instance-bbbbbbbb", node_instance: instance, enabled: true)
  end

  let!(:disabled_peer) do
    instance = create(:system_node_instance, node: node, name: "i-zzz")
    create_peer(handle: "instance-zzzzzzzz", node_instance: instance, enabled: false)
  end

  let!(:foreign_peer) do
    instance = create(:system_node_instance, node: other_node, name: "i-foreign")
    ::System::AgentPeeringService.announce!(
      node_instance: instance, capabilities: {}, skills: [], addresses: []
    ).peer.update!(handle: "instance-foreign1", enabled: true)
  end

  it "returns enabled peers scoped to the current account" do
    get "/api/v1/system/node_instance_peers/searchable", headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body).fetch("data")
    handles = body["peers"].map { |p| p["handle"] }

    expect(handles).to contain_exactly("instance-aaaaaaaa", "instance-bbbbbbbb")
  end

  it "excludes disabled peers" do
    get "/api/v1/system/node_instance_peers/searchable", headers: headers

    handles = JSON.parse(response.body).dig("data", "peers").map { |p| p["handle"] }
    expect(handles).not_to include("instance-zzzzzzzz")
  end

  it "excludes peers from other accounts (cross-tenant isolation)" do
    get "/api/v1/system/node_instance_peers/searchable", headers: headers

    handles = JSON.parse(response.body).dig("data", "peers").map { |p| p["handle"] }
    expect(handles).not_to include("instance-foreign1")
  end

  it "filters by handle prefix via the q param" do
    get "/api/v1/system/node_instance_peers/searchable?q=instance-aa", headers: headers

    handles = JSON.parse(response.body).dig("data", "peers").map { |p| p["handle"] }
    expect(handles).to contain_exactly("instance-aaaaaaaa")
  end

  it "tolerates a leading @ in the q param (matches workspace mention input)" do
    get "/api/v1/system/node_instance_peers/searchable?q=@instance-bb", headers: headers

    handles = JSON.parse(response.body).dig("data", "peers").map { |p| p["handle"] }
    expect(handles).to contain_exactly("instance-bbbbbbbb")
  end

  it "returns the lightweight serialization shape" do
    get "/api/v1/system/node_instance_peers/searchable", headers: headers

    peer = JSON.parse(response.body).dig("data", "peers").first
    expect(peer.keys).to contain_exactly(
      "id", "handle", "status", "node_instance_id", "node_name", "addresses"
    )
  end

  it "returns 403 without system.peers.read permission" do
    unprivileged = user_with_permissions("system.modules.read", account: account)
    get "/api/v1/system/node_instance_peers/searchable", headers: auth_headers_for(unprivileged)

    expect(response).to have_http_status(:forbidden)
  end

  it "returns 401 without authentication" do
    get "/api/v1/system/node_instance_peers/searchable"

    expect(response).to have_http_status(:unauthorized)
  end
end
