# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::FederationApi::Heartbeat", type: :request do
  let(:account) { create(:account) }
  let(:peer)    { enrolled_federation_peer(account: account) }
  let(:path)    { "/api/v1/system/federation_api/heartbeat" }
  let(:mtls_headers) { federation_mtls_headers(peer) }

  describe "POST /heartbeat (happy path)" do
    it "transitions enrolled → active on first heartbeat" do
      peer  # eager-create

      post path,
           params: { capabilities: { "v" => 2 },
                     endpoints: [ { url: "https://peer.example.com:443", scope: "wan", priority: 1 } ],
                     sync_cursor: { "accounts" => { "last_id" => "abc" } } },
           headers: mtls_headers,
           as: :json

      expect(response).to have_http_status(:ok)
      peer.reload
      expect(peer.status).to eq("active")
      expect(peer.capabilities).to eq("v" => 2)
      expect(peer.last_heartbeat_at).to be_within(2.seconds).of(Time.current)
    end

    it "keeps an active peer active (refreshing heartbeat)" do
      peer.update!(status: "active", last_heartbeat_at: 1.minute.ago)

      post path, params: {}, headers: mtls_headers, as: :json

      expect(response).to have_http_status(:ok)
      peer.reload
      expect(peer.status).to eq("active")
      expect(peer.last_heartbeat_at).to be_within(2.seconds).of(Time.current)
    end

    it "transitions degraded → active on recovery heartbeat" do
      peer.update!(status: "degraded")

      post path, params: {}, headers: mtls_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(peer.reload.status).to eq("active")
    end
  end

  describe "POST /heartbeat (auth failures)" do
    it "401s without an mTLS subject header" do
      peer
      post path, params: {}, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "401s when the forwarded CN matches no peer" do
      post path, params: {},
           headers: federation_cert_info_header("fed:#{SecureRandom.uuid}"),
           as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "401s when the peer is not in a reachable status (suspended)" do
      peer.update!(status: "suspended")
      post path, params: {}, headers: mtls_headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "401s when an sdwan_only peer presents a matching CN (federation_api is platform-only)" do
      sdwan_peer = create(:system_federation_peer, account: account, status: "accepted")
      sdwan_peer.update_column(:inbound_subject, "fed:#{sdwan_peer.id}")

      post path, params: {},
           headers: federation_cert_info_header(sdwan_peer.inbound_subject),
           as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
