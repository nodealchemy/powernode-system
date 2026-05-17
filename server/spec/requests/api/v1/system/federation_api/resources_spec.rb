# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::FederationApi::Resources", type: :request do
  let(:account) { create(:account) }
  let(:grantor) { create(:user, account: account) }
  let(:cert) do
    ::System::NodeCertificate.create!(
      account: account, subject_kind: "federation_peer",
      subject: "federation-peer-#{SecureRandom.uuid}",
      serial: SecureRandom.hex(16),
      not_before: 1.day.ago, not_after: 180.days.from_now,
      pem_chain: "stub", issuer_subject: "Powernode Internal CA"
    )
  end
  let(:peer) do
    create(:system_federation_peer, :active,
           account: account, node_certificate: cert)
  end

  let(:mtls_headers) { { "SSL_CLIENT_S_DN_CN" => cert.id } }

  before do
    # Install a fake inventory so "skill" is a known kind without
    # requiring a real federation_inventory.yaml on disk.
    fake_registry = System::Federation::InventoryRegistry.new
    fake_registry.register_kind(
      System::Federation::InventoryRegistry::Kind.new(
        extension: "demo",
        kind: "skill",
        dependencies: [],
        duplicable: true,
        migratable: false,
        metadata: {}
      )
    )
    System::Federation::InventoryRegistry.install_test_double(fake_registry)
  end

  after { System::Federation::InventoryRegistry.install_test_double(nil) }

  let(:resource_uuid) { SecureRandom.uuid }
  let(:path)          { "/api/v1/system/federation_api/resources/skill/#{resource_uuid}" }

  describe "GET /resources/:kind/:id (happy path)" do
    let!(:grant) do
      create(:system_federation_grant,
             account: account, federation_peer: peer,
             grantor_user: grantor,
             remote_subject: "bob@b",
             resource_kind: "skill",
             resource_id: resource_uuid,
             permission_scopes: [ "read" ])
    end

    it "returns 200 with the envelope" do
      get path,
          headers: mtls_headers.merge("Authorization" => "Bearer #{grant.bearer_token}")

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      data = body["data"] || body
      expect(data["kind"]).to eq("skill")
      expect(data["id"]).to eq(resource_uuid)
      expect(data["grant_id"]).to eq(grant.id)
      expect(data["account_id"]).to eq(account.id)
      expect(data["fetched_at"]).to be_present
    end

    it "honors kind-wide grants (resource_id nil)" do
      kind_wide = create(:system_federation_grant,
                          account: account, federation_peer: peer,
                          grantor_user: grantor,
                          remote_subject: "bob@b",
                          resource_kind: "skill",
                          resource_id: nil,
                          permission_scopes: [ "read" ])
      # Delete the specific-resource grant so the kind-wide is the only match
      grant.destroy

      get path,
          headers: mtls_headers.merge("Authorization" => "Bearer #{kind_wide.bearer_token}")
      expect(response).to have_http_status(:ok)
    end
  end

  describe "auth failures" do
    let!(:grant) do
      create(:system_federation_grant,
             account: account, federation_peer: peer,
             grantor_user: grantor,
             remote_subject: "bob@b",
             resource_kind: "skill",
             resource_id: resource_uuid,
             permission_scopes: [ "read" ])
    end

    it "401 without Bearer token" do
      get path, headers: mtls_headers
      expect(response).to have_http_status(:unauthorized)
    end

    it "401 with malformed Bearer token" do
      get path, headers: mtls_headers.merge("Authorization" => "Bearer bogus")
      expect(response).to have_http_status(:unauthorized)
    end

    it "401 when grant belongs to a different peer" do
      other_account = create(:account)
      other_peer = create(:system_federation_peer, :active, account: other_account)
      other_grant = create(:system_federation_grant,
                            account: other_account, federation_peer: other_peer,
                            grantor_user: create(:user, account: other_account),
                            remote_subject: "anyone",
                            resource_kind: "skill",
                            resource_id: resource_uuid,
                            permission_scopes: [ "read" ])
      get path,
          headers: mtls_headers.merge("Authorization" => "Bearer #{other_grant.bearer_token}")
      expect(response).to have_http_status(:unauthorized)
    end

    it "401 when grant is expired" do
      grant.update_columns(issued_at: 60.days.ago, expires_at: 1.day.ago)
      get path,
          headers: mtls_headers.merge("Authorization" => "Bearer #{grant.bearer_token}")
      expect(response).to have_http_status(:unauthorized)
    end

    it "401 when grant is revoked" do
      grant.revoke!(reason: "test")
      get path,
          headers: mtls_headers.merge("Authorization" => "Bearer #{grant.bearer_token}")
      expect(response).to have_http_status(:unauthorized)
    end

    it "403 when grant resource_kind doesn't match request kind" do
      grant.update!(resource_kind: "other_kind")
      # Need to also re-register the kind we're requesting since registry
      # checks happen too — but base auth fires first
      get path,
          headers: mtls_headers.merge("Authorization" => "Bearer #{grant.bearer_token}")
      expect(response).to have_http_status(:forbidden)
    end

    it "403 when grant lacks read scope" do
      grant.update!(permission_scopes: %w[admin])  # admin but no read
      get path,
          headers: mtls_headers.merge("Authorization" => "Bearer #{grant.bearer_token}")
      expect(response).to have_http_status(:forbidden)
    end

    it "403 when specific-resource grant targets a different id" do
      grant.update!(resource_id: SecureRandom.uuid)  # different from URL
      get path,
          headers: mtls_headers.merge("Authorization" => "Bearer #{grant.bearer_token}")
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "unknown kind" do
    let!(:grant) do
      create(:system_federation_grant,
             account: account, federation_peer: peer,
             grantor_user: grantor,
             remote_subject: "bob@b",
             resource_kind: "rogue_kind",
             resource_id: resource_uuid,
             permission_scopes: [ "read" ])
    end

    it "422 when kind is not in the inventory registry" do
      get "/api/v1/system/federation_api/resources/rogue_kind/#{resource_uuid}",
          headers: mtls_headers.merge("Authorization" => "Bearer #{grant.bearer_token}")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("federation_inventory.yaml")
    end
  end
end
