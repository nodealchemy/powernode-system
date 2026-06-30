# frozen_string_literal: true

require "rails_helper"

# N+1 regression guards for the four SDWAN operator index endpoints whose
# serializers issued one query per row. Each example asserts BOTH that the
# per-child-table query count stays flat (<= 1) regardless of page size (per
# QueryCountHelper) AND that the eager-loaded value still matches the original
# per-row computation.
RSpec.describe "SDWAN operator index endpoints — N+1 regression", type: :request do
  let(:user) do
    user_with_permissions(
      "system.sdwan.networks.read",
      "system.sdwan.peers.read",
      "system.sdwan.vips.read",
      "system.sdwan.user_devices.manage"
    )
  end
  let(:account) { user.account }
  let(:headers) { auth_headers_for(user) }
  let(:network) { create(:sdwan_network, account: account) }

  def data
    JSON.parse(response.body)["data"]
  end

  it "GET /networks: flat peer COUNT + correct peer_count value" do
    create_list(:sdwan_peer, 2, account: account, network: network)
    create_list(:sdwan_network, 2, account: account) # extra rows to expose the N+1

    queries = count_queries(/\bsystem_sdwan_peers\b/) do
      get "/api/v1/system/sdwan/networks", headers: headers
    end

    expect(response).to have_http_status(:ok)
    expect(queries).to be <= 1
    mine = data["networks"].find { |n| n["id"] == network.id }
    expect(mine["peer_count"]).to eq(2)
  end

  it "GET /networks/:id/peers: flat subnet_advertisement COUNT + correct prefix count" do
    create_list(:sdwan_peer, 3, account: account, network: network)

    queries = count_queries(/\bsystem_sdwan_subnet_advertisements\b/) do
      get "/api/v1/system/sdwan/networks/#{network.id}/peers", headers: headers
    end

    expect(response).to have_http_status(:ok)
    expect(queries).to be <= 1
    expect(data["peers"].map { |p| p["advertised_prefix_count"] }).to all(eq(0))
  end

  it "GET .../user_devices: no per-device network load + correct network_id" do
    grant = create(:sdwan_access_grant, account: account, network: network)
    3.times { create(:sdwan_user_device, access_grant: grant) }

    queries = count_queries(/\bsystem_sdwan_networks\b/) do
      get "/api/v1/system/sdwan/networks/#{network.id}/access_grants/#{grant.id}/user_devices",
          headers: headers
    end

    expect(response).to have_http_status(:ok)
    # 1 query is set_network's own load; the per-device network walk must be gone.
    expect(queries).to be <= 1
    expect(data["user_devices"].map { |d| d["network_id"] }).to all(eq(network.id))
  end

  it "GET /networks/:id/virtual_ips: one batched holder load + correct primary holder" do
    peers = create_list(:sdwan_peer, 3, account: account, network: network)
    peers.each_with_index do |peer, i|
      create(:sdwan_virtual_ip, account: account, network: network,
             name: "vip-nplus1-#{i}", holder_peer_ids: [ peer.id ])
    end

    queries = count_queries(/\bsystem_sdwan_peers\b/) do
      get "/api/v1/system/sdwan/networks/#{network.id}/virtual_ips", headers: headers
    end

    expect(response).to have_http_status(:ok)
    expect(queries).to be <= 1
    returned = data["virtual_ips"].map { |v| v["primary_holder_peer_id"] }
    expect(returned).to match_array(peers.map(&:id))
  end
end
