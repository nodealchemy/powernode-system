# frozen_string_literal: true

require "rails_helper"

# Phase O6 of the OVS+OVN dual-profile networking roadmap.
RSpec.describe "Api::V1::System::Sdwan::HostBridges", type: :request do
  let(:user)    { user_with_permissions("sdwan.host_bridges.read") }
  let(:account) { user.account }
  let(:headers) { auth_headers_for(user) }

  let(:platform)   { create(:system_node_platform, account: account) }
  let(:template)   { create(:system_node_template, account: account, node_platform: platform) }
  let(:node_a)     { create(:system_node, account: account, node_template: template, name: "n-a") }
  let(:node_b)     { create(:system_node, account: account, node_template: template, name: "n-b") }
  let(:instance_a) { create(:system_node_instance, :running, node: node_a) }
  let(:instance_b) { create(:system_node_instance, :running, node: node_b) }

  before do
    Sdwan::HostBridge.where(account_id: account.id).delete_all
  end

  describe "GET /api/v1/system/sdwan/host_bridges" do
    it "returns an empty list when no bridges exist" do
      get "/api/v1/system/sdwan/host_bridges", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json_response_data["host_bridges"]).to eq([])
      expect(json_response_data["count"]).to eq(0)
    end

    it "lists bridges scoped to the current account only" do
      ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      other_account = create(:account)
      other_node = create(:system_node, account: other_account, node_template: template)
      other_instance = create(:system_node_instance, :running, node: other_node)
      ::Sdwan::HostBridgeAllocator.allocate!(host: other_instance, kind: "linux", account: other_account)

      get "/api/v1/system/sdwan/host_bridges", headers: headers
      expect(response).to have_http_status(:ok)
      ids = json_response_data["host_bridges"].map { |b| b["node_instance_id"] }
      expect(ids).to contain_exactly(instance_a.id)
    end

    it "includes node_instance_name + network_profile in each row" do
      ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      get "/api/v1/system/sdwan/host_bridges", headers: headers
      row = json_response_data["host_bridges"].first
      expect(row["node_instance_name"]).to eq(instance_a.name)
      expect(row["network_profile"]).to eq("lightweight")
      expect(row["bridge_name"]).to start_with("pwnbr-")
    end

    it "filters by node_instance_id" do
      ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      ::Sdwan::HostBridgeAllocator.allocate!(host: instance_b, kind: "linux")

      get "/api/v1/system/sdwan/host_bridges",
          params: { node_instance_id: instance_a.id }, headers: headers
      ids = json_response_data["host_bridges"].map { |b| b["node_instance_id"] }
      expect(ids).to contain_exactly(instance_a.id)
      expect(json_response_data["filters"]["node_instance_id"]).to eq(instance_a.id)
    end

    it "filters by state" do
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      ::Sdwan::HostBridgeAllocator.allocate!(host: instance_b, kind: "linux")
      bridge.mark_active!

      get "/api/v1/system/sdwan/host_bridges",
          params: { state: "active" }, headers: headers
      states = json_response_data["host_bridges"].map { |b| b["state"] }
      expect(states).to eq([ "active" ])
    end

    it "filters by kind" do
      ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      instance_b.update!(network_profile: "heavyweight")
      ::Sdwan::HostBridgeAllocator.allocate!(host: instance_b)

      get "/api/v1/system/sdwan/host_bridges",
          params: { kind: "ovs" }, headers: headers
      kinds = json_response_data["host_bridges"].map { |b| b["kind"] }
      expect(kinds).to eq([ "ovs" ])
    end

    it "rejects without the read permission" do
      no_perm_user = user_with_permissions("sdwan.networks.read")
      get "/api/v1/system/sdwan/host_bridges", headers: auth_headers_for(no_perm_user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/system/sdwan/host_bridges/:id" do
    it "returns the full bridge shape with timestamps" do
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      bridge.mark_active!

      get "/api/v1/system/sdwan/host_bridges/#{bridge.id}", headers: headers
      expect(response).to have_http_status(:ok)
      payload = json_response_data["host_bridge"]
      expect(payload["id"]).to eq(bridge.id)
      expect(payload["state"]).to eq("active")
      expect(payload["applied_at"]).to be_present
      expect(payload["created_at"]).to be_present
    end

    it "returns 404 for a bridge in a different account" do
      other_account = create(:account)
      other_node = create(:system_node, account: other_account, node_template: template)
      other_instance = create(:system_node_instance, :running, node: other_node)
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: other_instance, kind: "linux", account: other_account)

      get "/api/v1/system/sdwan/host_bridges/#{bridge.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/system/sdwan/host_bridges/:id" do
    let(:manager) { user_with_permissions("sdwan.host_bridges.read", "sdwan.host_bridges.manage", account: account) }
    let(:manager_headers) { auth_headers_for(manager) }

    it "force-removes the bridge (state → removed) and returns deleted=true" do
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")

      delete "/api/v1/system/sdwan/host_bridges/#{bridge.id}", headers: manager_headers

      expect(response).to have_http_status(:ok)
      expect(json_response_data["deleted"]).to be true
      expect(::Sdwan::HostBridge.find(bridge.id).state).to eq("removed")
    end

    it "rejects without sdwan.host_bridges.manage permission" do
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      delete "/api/v1/system/sdwan/host_bridges/#{bridge.id}", headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end
end
