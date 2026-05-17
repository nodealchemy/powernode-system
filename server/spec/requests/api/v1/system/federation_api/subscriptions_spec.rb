# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::FederationApi::Subscriptions", type: :request do
  let(:operator_account) { create(:account) }
  let(:cert) do
    ::System::NodeCertificate.create!(
      account: operator_account, subject_kind: "federation_peer",
      subject: "federation-peer-#{SecureRandom.uuid}",
      serial: SecureRandom.hex(16),
      not_before: 1.day.ago, not_after: 180.days.from_now,
      pem_chain: "stub", issuer_subject: "Powernode Internal CA"
    )
  end
  # let! — must eagerly create so the mTLS lookup in BaseController
  # finds a FederationPeer linked to this cert.
  let!(:peer) do
    create(:system_federation_peer, :platform, :active,
           account: operator_account, node_certificate: cert)
  end
  let(:mtls_headers) { { "SSL_CLIENT_S_DN_CN" => cert.id, "Content-Type" => "application/json" } }

  let(:path) { "/api/v1/system/federation_api/subscriptions" }

  describe "POST /subscriptions (happy path)" do
    let!(:offering) do
      create(:system_federation_service_offering, :active,
              account: operator_account, slug: "gitea",
              backend_host: "backend.example.com", backend_port: 443,
              protocol: "https",
              default_grant_ttl_days: 30)
    end

    it "creates a FederationGrant + returns connection details (201)" do
      post path,
           params: { slug: "gitea", local_hostname: "git.alice.tld" }.to_json,
           headers: mtls_headers

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      data = body["data"]
      expect(data["grant_id"]).to be_present
      expect(data["backend_host"]).to eq("backend.example.com")
      expect(data["backend_port"]).to eq(443)
      expect(data["protocol"]).to eq("https")
      expect(data["service_offering_id"]).to eq(offering.id)
      expect(data["ttl_seconds"]).to be_within(60).of(30.days.to_i)

      grant = ::System::FederationGrant.find(data["grant_id"])
      expect(grant.federation_peer_id).to eq(peer.id)
      expect(grant.resource_kind).to eq("service_offering")
      expect(grant.resource_id).to eq(offering.id)
    end

    it "supports custom ttl_days" do
      post path,
           params: { slug: "gitea", local_hostname: "git.alice.tld", ttl_days: 90 }.to_json,
           headers: mtls_headers
      data = JSON.parse(response.body)["data"]
      expect(data["ttl_seconds"]).to be_within(60).of(90.days.to_i)
    end
  end

  describe "POST /subscriptions (errors)" do
    let!(:offering) { create(:system_federation_service_offering, :active, account: operator_account, slug: "gitea") }

    it "400 when slug is missing" do
      post path,
           params: { local_hostname: "git.alice.tld" }.to_json,
           headers: mtls_headers
      expect(response).to have_http_status(:bad_request)
    end

    it "400 when local_hostname is missing" do
      post path,
           params: { slug: "gitea" }.to_json,
           headers: mtls_headers
      expect(response).to have_http_status(:bad_request)
    end

    it "404 when offering slug is unknown" do
      post path,
           params: { slug: "nonexistent", local_hostname: "git.alice.tld" }.to_json,
           headers: mtls_headers
      expect(response).to have_http_status(:not_found)
    end

    it "409 when offering is deprecated" do
      offering.deprecate!
      post path,
           params: { slug: "gitea", local_hostname: "git.alice.tld" }.to_json,
           headers: mtls_headers
      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to match(/not accepting/)
    end

    it "409 when offering is at capacity" do
      offering.update!(capacity_metadata: { "max_subscribers" => 0 })
      post path,
           params: { slug: "gitea", local_hostname: "git.alice.tld" }.to_json,
           headers: mtls_headers
      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to match(/at capacity/)
    end

    it "401 without mTLS" do
      post path,
           params: { slug: "gitea", local_hostname: "git.alice.tld" }.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE /subscriptions/:id" do
    let!(:offering) { create(:system_federation_service_offering, :active, account: operator_account, slug: "gitea") }
    let!(:grant) do
      create(:system_federation_grant,
              account: operator_account, federation_peer: peer,
              grantor_user: nil,
              remote_subject: "service-sub:gitea:git.alice.tld@peer-#{peer.id}",
              resource_kind: "service_offering",
              resource_id: offering.id,
              permission_scopes: %w[read])
    end

    it "revokes the grant + returns 200" do
      delete "#{path}/#{grant.id}", headers: mtls_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"]["revoked"]).to be true
      grant.reload
      expect(grant.revoked?).to be true
      expect(grant.revoked_at).to be_present
    end

    it "404 when grant id is unknown" do
      delete "#{path}/#{SecureRandom.uuid}", headers: mtls_headers
      expect(response).to have_http_status(:not_found)
    end

    it "404 when grant belongs to a different peer" do
      other_account = create(:account)
      other_peer = create(:system_federation_peer, :platform, :active, account: other_account)
      other_grant = create(:system_federation_grant,
                            account: other_account, federation_peer: other_peer,
                            grantor_user: create(:user, account: other_account),
                            remote_subject: "other-sub",
                            resource_kind: "service_offering",
                            resource_id: SecureRandom.uuid,
                            permission_scopes: %w[read])
      delete "#{path}/#{other_grant.id}", headers: mtls_headers
      expect(response).to have_http_status(:not_found)
    end

    it "404 when grant is for a different resource_kind (cross-endpoint guard)" do
      misc_grant = create(:system_federation_grant,
                          account: operator_account, federation_peer: peer,
                          grantor_user: create(:user, account: operator_account),
                          remote_subject: "misc",
                          resource_kind: "skill",  # not service_offering
                          resource_id: SecureRandom.uuid,
                          permission_scopes: %w[read])
      delete "#{path}/#{misc_grant.id}", headers: mtls_headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
