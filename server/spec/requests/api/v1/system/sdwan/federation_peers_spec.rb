# frozen_string_literal: true

require "rails_helper"

# Trust-boundary coverage for the federation-peer controller (previously zero
# request-spec coverage). Federation peering is a cross-instance trust boundary:
# read endpoints gate on sdwan.federation.read, mutate endpoints on
# sdwan.federation.manage, peers are account-scoped (IDOR), and status writes
# are constrained to the V1_TRANSITIONS state machine (illegal flips -> 422).
RSpec.describe "Api::V1::System::Sdwan::FederationPeers", type: :request do
  let(:account)  { create(:account) }
  let(:reader)   { user_with_permissions("system.sdwan.federation.read", account: account) }
  let(:manager)  { user_with_permissions("system.sdwan.federation.read", "system.sdwan.federation.manage", account: account) }
  let(:stranger) { user_with_permissions("system.sdwan.networks.read", account: account) }

  describe "GET /api/v1/system/sdwan/federation_peers" do
    it "forbids callers without sdwan.federation.read" do
      get "/api/v1/system/sdwan/federation_peers", headers: auth_headers_for(stranger)
      expect(response).to have_http_status(:forbidden)
    end

    it "lists only the caller's own account peers (IDOR scoping)" do
      mine  = create(:system_federation_peer, account: account)
      other = create(:system_federation_peer) # different account

      get "/api/v1/system/sdwan/federation_peers", headers: auth_headers_for(reader)

      expect(response).to have_http_status(:ok)
      ids = json_response_data["federation_peers"].map { |p| p["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(other.id)
    end
  end

  describe "GET /api/v1/system/sdwan/federation_peers/:id" do
    it "404s for a peer in another account (IDOR guard)" do
      foreign = create(:system_federation_peer) # different account

      get "/api/v1/system/sdwan/federation_peers/#{foreign.id}", headers: auth_headers_for(reader)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/system/sdwan/federation_peers/:id" do
    let(:peer) { create(:system_federation_peer, account: account, status: "proposed") }

    it "forbids mutation with read-only permission (permission split)" do
      patch "/api/v1/system/sdwan/federation_peers/#{peer.id}",
            params: { federation_peer: { remote_instance_url: "https://x.example.com" } }.to_json,
            headers: auth_headers_for(reader).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:forbidden)
    end

    it "rejects an illegal v1 status transition with 422" do
      # V1_TRANSITIONS["proposed"] = [accepted, revoked]; "active" is not allowed.
      patch "/api/v1/system/sdwan/federation_peers/#{peer.id}",
            params: { federation_peer: { status: "active" } }.to_json,
            headers: auth_headers_for(manager).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to match(/not permitted in v1/i)
      expect(peer.reload.status).to eq("proposed")
    end
  end

  describe "POST /api/v1/system/sdwan/federation_peers/:id/revoke" do
    it "requires sdwan.federation.manage (the approval-gated revoke is behind the manage permission)" do
      peer = create(:system_federation_peer, account: account, status: "accepted")

      post "/api/v1/system/sdwan/federation_peers/#{peer.id}/revoke", headers: auth_headers_for(reader)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
