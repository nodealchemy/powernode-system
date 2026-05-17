# frozen_string_literal: true

require "rails_helper"

# Plan reference: Decentralized Federation §E + §I + P4 + P7.5.
RSpec.describe "Api::V1::System::Platform::PeerGrants", type: :request do
  let(:account) { create(:account) }
  let(:reader)  { user_with_permissions("system.peers.read", account: account) }
  let(:manager) { user_with_permissions("system.peers.read", "system.peers.manage", account: account) }
  let!(:peer) do
    create(:system_federation_peer, :active, account: account)
  end
  let(:base) { "/api/v1/system/platform/peers/#{peer.id}/grants" }

  describe "GET /grants" do
    let!(:active_grant) do
      create(:system_federation_grant, account: account, federation_peer: peer,
                                        remote_subject: "alice@b.example.org",
                                        resource_kind: "skill",
                                        permission_scopes: %w[read],
                                        issued_at: 1.day.ago,
                                        expires_at: 29.days.from_now)
    end
    let!(:revoked_grant) do
      g = create(:system_federation_grant, account: account, federation_peer: peer,
                                            remote_subject: "alice@b.example.org",
                                            resource_kind: "trading_strategy",
                                            permission_scopes: %w[read])
      g.revoke!(reason: "test")
      g
    end
    let!(:other_peer_grant) do
      other = create(:system_federation_peer, :active, account: account)
      create(:system_federation_grant, account: account, federation_peer: other)
    end

    it "lists grants for this peer only with lifecycle pills" do
      get base, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)

      data = json_response_data
      expect(data["count"]).to eq(2)
      lifecycles = data["grants"].map { |g| g["lifecycle"] }.sort
      expect(lifecycles).to eq(%w[active revoked])
    end

    it "filters by state=active" do
      get base, headers: auth_headers_for(reader), params: { state: "active" }
      data = json_response_data
      expect(data["grants"].map { |g| g["lifecycle"] }).to eq([ "active" ])
    end

    it "forbids without read permission" do
      anon = create(:user, account: account)
      get base, headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /grants" do
    let(:valid_body) do
      {
        resource_kind: "skill",
        remote_subject: "bob@b.example.org",
        permission_scopes: %w[read write],
        ttl_days: 14,
        source_cidrs: [ "10.0.0.0/24" ]
      }
    end

    it "issues a grant with pessimistic CIDR scope" do
      post base, params: valid_body, headers: auth_headers_for(manager), as: :json
      expect(response).to have_http_status(:created)

      grant = json_response_data["grant"]
      expect(grant["lifecycle"]).to eq("active")
      expect(grant["unrestricted"]).to be false
      expect(grant["source_cidrs"]).to eq([ "10.0.0.0/24" ])
      expect(grant["bearer_token_preview"]).to start_with("fg-")
    end

    it "clamps TTL to MIN_TTL when below 7 days" do
      post base, params: valid_body.merge(ttl_days: 1),
                 headers: auth_headers_for(manager), as: :json
      expect(response).to have_http_status(:created)

      grant = json_response_data["grant"]
      ttl_days = ((Time.parse(grant["expires_at"]) - Time.parse(grant["issued_at"])) / 86_400).round
      expect(ttl_days).to be >= 7
    end

    it "rejects invalid permission_scopes" do
      post base, params: valid_body.merge(permission_scopes: %w[read bogus]),
                 headers: auth_headers_for(manager), as: :json
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects missing resource_kind" do
      post base, params: valid_body.except(:resource_kind),
                 headers: auth_headers_for(manager), as: :json
      expect(response).to have_http_status(:bad_request)
    end

    it "forbids without manage permission" do
      post base, params: valid_body, headers: auth_headers_for(reader), as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /grants/:id/revoke" do
    let!(:grant) do
      create(:system_federation_grant, account: account, federation_peer: peer,
                                        remote_subject: "carol@b.example.org",
                                        resource_kind: "skill")
    end

    it "soft-revokes the grant" do
      post "#{base}/#{grant.id}/revoke", params: { reason: "operator" },
                                          headers: auth_headers_for(manager), as: :json
      expect(response).to have_http_status(:ok)

      data = json_response_data["grant"]
      expect(data["lifecycle"]).to eq("revoked")
      expect(data["revocation_reason"]).to eq("operator")
      expect(data["revoked_at"]).to be_present
      expect(data["archived_at"]).to be_nil
    end

    it "409s when already revoked" do
      grant.revoke!(reason: "first revoke")
      post "#{base}/#{grant.id}/revoke", headers: auth_headers_for(manager), as: :json
      expect(response).to have_http_status(:conflict)
    end

    it "404s for unknown grant id" do
      post "#{base}/nonexistent/revoke", headers: auth_headers_for(manager), as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end
