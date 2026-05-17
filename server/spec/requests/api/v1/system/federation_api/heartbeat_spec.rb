# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::FederationApi::Heartbeat", type: :request do
  let(:account) { create(:account) }
  let(:cert) do
    # Direct create (no factory yet for system_node_certificates with
    # subject_kind = "federation_peer"). Instance is nil for federation
    # peer certs.
    ::System::NodeCertificate.create!(
      account: account,
      subject_kind: "federation_peer",
      subject: "federation-peer-#{SecureRandom.uuid}",
      serial: SecureRandom.hex(16),
      not_before: 1.day.ago,
      not_after: 180.days.from_now,
      pem_chain: "stub-pem",
      issuer_subject: "Powernode Internal CA"
    )
  end
  let(:peer) do
    create(:system_federation_peer, :enrolled,
           account: account,
           node_certificate: cert)
  end
  let(:path) { "/api/v1/system/federation_api/heartbeat" }

  let(:mtls_headers) do
    # Simulate the reverse proxy forwarding the verified subject CN.
    { "SSL_CLIENT_S_DN_CN" => cert.id }
  end

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
    it "401s without mTLS subject header" do
      peer
      post path, params: {}, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "401s when cert is not subject_kind=federation_peer" do
      instance_cert = ::System::NodeCertificate.create!(
        account: account,
        subject_kind: "instance",
        subject: "instance-xyz",
        serial: SecureRandom.hex(16),
        not_before: 1.day.ago,
        not_after: 180.days.from_now,
        pem_chain: "stub",
        issuer_subject: "Powernode Internal CA"
      )
      post path, params: {},
           headers: { "SSL_CLIENT_S_DN_CN" => instance_cert.id },
           as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "401s when no FederationPeer is bound to the cert" do
      orphan_cert = ::System::NodeCertificate.create!(
        account: account,
        subject_kind: "federation_peer",
        subject: "orphan-#{SecureRandom.uuid}",
        serial: SecureRandom.hex(16),
        not_before: 1.day.ago,
        not_after: 180.days.from_now,
        pem_chain: "stub",
        issuer_subject: "Powernode Internal CA"
      )
      post path, params: {},
           headers: { "SSL_CLIENT_S_DN_CN" => orphan_cert.id },
           as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "401s when peer is suspended" do
      peer.update!(status: "suspended")
      post path, params: {}, headers: mtls_headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "401s when cert is revoked" do
      cert.update!(revoked_at: Time.current, revocation_reason: "rotation")
      post path, params: {}, headers: mtls_headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
