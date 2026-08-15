# frozen_string_literal: true

require "rails_helper"

# IMP-1c08ab7f5ecd — the peers index serializer's effective_endpoint must
# bracket an IPv6-literal host so host and port stay separable, while a
# hostname stored in the v6 column stays bare (family :v6 does not imply a
# literal — the validation accepts hostnames).
RSpec.describe "SDWAN peers index — effective_endpoint bracketing", type: :request do
  let(:user)    { user_with_permissions("system.sdwan.peers.read") }
  let(:account) { user.account }
  let(:headers) { auth_headers_for(user) }
  let(:network) { create(:sdwan_network, account: account) }

  it "brackets a v6-literal primary endpoint and leaves a hostname bare" do
    v6_hub   = create(:sdwan_peer, :hub, account: account, network: network)
    name_hub = create(:sdwan_peer, :hub, account: account, network: network,
                                         endpoint_host_v6: "edge.example.net")

    get "/api/v1/system/sdwan/networks/#{network.id}/peers", headers: headers

    expect(response).to have_http_status(:ok)
    peers = JSON.parse(response.body)["data"]["peers"].index_by { |p| p["id"] }
    expect(peers.fetch(v6_hub.id)["effective_endpoint"]).to eq("[fd00:abcd:1::1]:51820")
    expect(peers.fetch(name_hub.id)["effective_endpoint"]).to eq("edge.example.net:51820")
  end
end
