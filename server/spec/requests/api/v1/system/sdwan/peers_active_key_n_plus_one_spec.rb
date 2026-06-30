# frozen_string_literal: true

require "rails_helper"

# N+1 regression for Peer#active_key. The peers index eager-loads :keys, but
# active_key used keys.where(...) which re-queries per peer even when :keys is
# preloaded — defeating the includes and issuing one peer_keys query per row.
RSpec.describe "SDWAN peers index — Peer#active_key N+1", type: :request do
  let(:user)    { user_with_permissions("system.sdwan.peers.read") }
  let(:account) { user.account }
  let(:headers) { auth_headers_for(user) }
  let(:network) { create(:sdwan_network, account: account) }

  it "does not re-query peer keys once per peer, and still serializes the public key" do
    peers = create_list(:sdwan_peer, 3, account: account, network: network)
    peers.each { |p| Sdwan::KeyDistributor.ensure_key_for!(p) }

    queries = count_queries(/\bsystem_sdwan_peer_keys\b/) do
      get "/api/v1/system/sdwan/networks/#{network.id}/peers", headers: headers
    end

    expect(response).to have_http_status(:ok)
    expect(queries).to be <= 1 # only the includes(:keys) preload
    pubkeys = JSON.parse(response.body)["data"]["peers"].map { |p| p["public_key"] }
    expect(pubkeys.compact.size).to eq(3)
  end
end
