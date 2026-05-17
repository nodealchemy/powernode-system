# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::Federation::PeerCatalog", type: :request do
  let(:account) { create(:account) }
  let(:user) { user_with_permissions("system.service_subscriptions.read", account: account) }
  let(:headers) { auth_headers_for(user) }
  let(:peer) { create(:system_federation_peer, :platform, :active, account: account) }
  let(:path) { "/api/v1/system/federation/peers/#{peer.id}/catalog" }

  let(:stub_client) { instance_double("Federation::PeerClient") }

  before do
    allow(::Federation::PeerClient).to receive(:new).and_return(stub_client)
  end

  describe "GET /peers/:peer_id/catalog" do
    it "returns the peer's catalog on success" do
      allow(stub_client).to receive(:fetch_catalog).and_return(
        "offerings" => [ { "slug" => "gitea", "name" => "Hosted Git" } ],
        "generated_at" => "2026-05-16T12:00:00Z"
      )
      get path, headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"]["catalog"]["offerings"]).to eq([ { "slug" => "gitea", "name" => "Hosted Git" } ])
      expect(body["data"]["peer_id"]).to eq(peer.id)
    end

    it "404 when peer is unknown" do
      get "/api/v1/system/federation/peers/#{SecureRandom.uuid}/catalog", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "404 when peer belongs to a different account" do
      other_peer = create(:system_federation_peer, :platform, :active, account: create(:account))
      get "/api/v1/system/federation/peers/#{other_peer.id}/catalog", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "502 when peer returns HTTP error" do
      allow(stub_client).to receive(:fetch_catalog)
        .and_raise(::Federation::PeerClient::HttpError.new("offering schema mismatch", status: 422))
      get path, headers: headers
      expect(response).to have_http_status(:bad_gateway)
    end

    it "503 when peer is unreachable" do
      allow(stub_client).to receive(:fetch_catalog)
        .and_raise(::Federation::PeerClient::ConnectionError, "timeout")
      get path, headers: headers
      expect(response).to have_http_status(:service_unavailable)
    end

    it "403 without the read permission" do
      no_perm = create(:user, account: account)
      get path, headers: auth_headers_for(no_perm)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
