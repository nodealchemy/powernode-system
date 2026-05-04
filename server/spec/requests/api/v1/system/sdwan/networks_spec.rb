# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::Sdwan::Networks", type: :request do
  let(:user) { user_with_permissions("sdwan.networks.read", "sdwan.networks.manage", "sdwan.peers.read") }
  let(:account) { user.account }
  let(:headers) { auth_headers_for(user) }

  before do
    Sdwan::Configuration.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
  end

  describe "GET /api/v1/system/sdwan/networks" do
    it "returns an empty list when no networks exist" do
      get "/api/v1/system/sdwan/networks", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json_response_data["networks"]).to eq([])
    end

    it "lists networks for the current account only" do
      Sdwan::Network.create!(account_id: account.id, name: "ours")
      other = create(:account)
      Sdwan::Network.create!(account_id: other.id, name: "theirs")

      get "/api/v1/system/sdwan/networks", headers: headers
      expect(response).to have_http_status(:ok)
      names = json_response_data["networks"].map { |n| n["name"] }
      expect(names).to contain_exactly("ours")
    end
  end

  describe "POST /api/v1/system/sdwan/networks" do
    it "creates a network with auto-allocated /64" do
      post "/api/v1/system/sdwan/networks",
           params: { network: { name: "edge-overlay", description: "perimeter" } }.to_json,
           headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:created)
      net = json_response_data["network"]
      expect(net["name"]).to eq("edge-overlay")
      expect(net["cidr_64"]).to match(%r{\Afd[0-9a-f:]+::/64\z})
      expect(net["status"]).to eq("registered")
    end

    it "returns 422 with full error messages on duplicate name" do
      Sdwan::Network.create!(account_id: account.id, name: "duplicate")
      post "/api/v1/system/sdwan/networks",
           params: { network: { name: "duplicate" } }.to_json,
           headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response["errors"].to_s).to include("has already been taken")
    end
  end

  describe "GET /api/v1/system/sdwan/networks/:id" do
    it "returns the full network shape" do
      net = Sdwan::Network.create!(account_id: account.id, name: "show-test")
      get "/api/v1/system/sdwan/networks/#{net.id}", headers: headers
      expect(response).to have_http_status(:ok)
      payload = json_response_data["network"]
      expect(payload["id"]).to eq(net.id)
      expect(payload["hub_count"]).to eq(0)
      expect(payload["spoke_count"]).to eq(0)
    end

    it "returns 404 for a network in a different account" do
      other = create(:account)
      net = Sdwan::Network.create!(account_id: other.id, name: "not-yours")
      get "/api/v1/system/sdwan/networks/#{net.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/system/sdwan/networks/:id" do
    it "destroys the network and returns deleted=true" do
      net = Sdwan::Network.create!(account_id: account.id, name: "kill-me")
      delete "/api/v1/system/sdwan/networks/#{net.id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json_response_data["deleted"]).to eq(true)
      expect(Sdwan::Network.where(id: net.id).count).to eq(0)
    end
  end
end
