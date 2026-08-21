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

  # IMP-9bf58a693634 — the heartbeat is the one residency writer that is NOT
  # approval-gated (a remote peer declaring its OWN residency, on a request
  # that cannot park). It must still not change silently: FederationPeer's own
  # emitter fires only on saved_change_to_status?, so a residency-only write
  # used to leave no row on any audit surface — while it is the exact input
  # Federation::ResidencyEnforcer's boundary decision reads.
  describe "POST /heartbeat (declared data residency)" do
    def residency_events(peer)
      ::System::FleetEvent.where(account_id: peer.account_id,
                                 kind: "federation.peer.data_residency_changed")
                          .where("payload->>'federation_peer_id' = ?", peer.id)
    end

    it "audits a residency declaration that CHANGES the stored tag" do
      peer.update!(status: "active", data_residency: "us-east")

      post path, params: { data_residency: "eu-west" }, headers: mtls_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(peer.reload.data_residency).to eq("eu-west")

      event = residency_events(peer).first
      expect(event).to be_present, "a remote-driven residency change left no audit row"
      expect(event.payload["previous_data_residency"]).to eq("us-east")
      expect(event.payload["data_residency"]).to eq("eu-west")
      expect(event.payload["declared_by"]).to eq("remote_peer"),
                                              "the audit row does not distinguish a remote declaration from an operator's"
      expect(event.source).to eq("federation_heartbeat")
    end

    it "emits nothing when the heartbeat repeats the tag it already declared" do
      peer.update!(status: "active", data_residency: "eu-west")

      expect {
        post path, params: { data_residency: "eu-west" }, headers: mtls_headers, as: :json
      }.not_to change { residency_events(peer).count }

      expect(response).to have_http_status(:ok)
    end

    # The audit emit is best-effort HERE (unlike the gated executor, which
    # refuses to commit unaudited): an observability failure must not become a
    # federation liveness outage.
    it "still answers the heartbeat when the audit event cannot be emitted" do
      peer.update!(status: "active", data_residency: "us-east")
      allow(::System::Fleet::EventBroadcaster).to receive(:emit!).and_raise(StandardError, "sink down")

      post path, params: { data_residency: "eu-west" }, headers: mtls_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(peer.reload.data_residency).to eq("eu-west")
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
