# frozen_string_literal: true

require "rails_helper"

# IMP-b686e5068e21 — provider_network_subnets was a top-level flat resource
# in routes.rb, but ProviderNetworkSubnetsController#set_network requires
# params[:network_id], which a flat route never populates. Every real
# request 500'd (ActiveRecord::RecordNotFound from `.find(nil)`) regardless
# of what any caller sent. Fixed by nesting the resource under
# provider_networks/:network_id (matching the model's `network_id` column
# and the controller's existing param name).
RSpec.describe "Api::V1::System::ProviderNetworkSubnets", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.networks.read", account: account) }
  let(:create_user) { user_with_permissions("system.networks.create", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let(:network) { create(:system_provider_network, account: account) }
  let!(:subnet) { create(:system_provider_network_subnet, network: network) }

  describe "GET /api/v1/system/provider_networks/:network_id/provider_network_subnets" do
    it "returns 401 without auth" do
      get "/api/v1/system/provider_networks/#{network.id}/provider_network_subnets"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/provider_networks/#{network.id}/provider_network_subnets",
          headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "lists subnets for the network" do
      get "/api/v1/system/provider_networks/#{network.id}/provider_network_subnets",
          headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"]["subnets"].map { |s| s["id"] }).to contain_exactly(subnet.id)
    end

    it "returns 404 for another account's network" do
      foreign_network = create(:system_provider_network, account: other_account)
      get "/api/v1/system/provider_networks/#{foreign_network.id}/provider_network_subnets",
          headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/system/provider_networks/:network_id/provider_network_subnets/:id" do
    it "returns the subnet" do
      get "/api/v1/system/provider_networks/#{network.id}/provider_network_subnets/#{subnet.id}",
          headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["data"]["subnet"]["id"]).to eq(subnet.id)
    end
  end

  describe "POST /api/v1/system/provider_networks/:network_id/provider_network_subnets" do
    it "creates a subnet scoped to the network" do
      post "/api/v1/system/provider_networks/#{network.id}/provider_network_subnets",
           params: { subnet: { name: "subnet-b", cidr_block: "10.0.2.0/24", status: "available" } }.to_json,
           headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:created)
      expect(network.subnets.count).to eq(2)
    end
  end
end
