# frozen_string_literal: true

require "rails_helper"

# Plan reference: Decentralized Federation §I + P7.1.
RSpec.describe "Api::V1::System::Platform::Peers", type: :request do
  let(:account) { create(:account) }
  let(:reader)  { user_with_permissions("system.peers.read", account: account) }
  let(:inviter) { user_with_permissions("system.peers.read", "system.peers.invite", account: account) }
  let(:manager) { user_with_permissions("system.peers.read", "system.peers.manage", account: account) }
  let(:base)    { "/api/v1/system/platform/peers" }

  describe "GET /peers" do
    let!(:platform_peer) do
      create(:system_federation_peer, :platform, account: account,
                                                  remote_instance_url: "https://bob.example.org")
    end
    let!(:spawned_child_row) do
      # Children-side row (we are the parent) — filtered out from /peers
      create(:system_federation_peer, :spawned_parent_managed, account: account,
                                                                remote_instance_url: "https://child.example.org")
    end
    let!(:sdwan_only_peer) do
      # Legacy sdwan-only peer — also filtered out (peer_kind: platform only)
      create(:system_federation_peer, account: account,
                                       remote_instance_url: "https://sdwan-only.example.org")
    end
    let!(:cross_account_peer) do
      create(:system_federation_peer, :platform, account: create(:account),
                                                  remote_instance_url: "https://leak.example.org")
    end

    it "lists only this account's platform peers, excluding spawned-children and sdwan-only" do
      get base, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)

      urls = json_response_data["peers"].map { |p| p["remote_instance_url"] }
      expect(urls).to eq([ "https://bob.example.org" ])
      expect(urls).not_to include("https://child.example.org")
      expect(urls).not_to include("https://sdwan-only.example.org")
      expect(urls).not_to include("https://leak.example.org")
    end

    it "filters by status (comma-separated)" do
      create(:system_federation_peer, :active, account: account,
                                                remote_instance_url: "https://active.example.org")
      get base, headers: auth_headers_for(reader), params: { status: "active" }
      data = json_response_data
      expect(data["peers"].map { |p| p["status"] }).to eq([ "active" ])
    end

    it "forbids without read permission" do
      anon = create(:user, account: account)
      get base, headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /peers" do
    let(:valid_body) do
      {
        remote_instance_url: "https://newpeer.example.org",
        spawn_role: "symmetric",
        spawn_mode: "out_of_band",
        endpoints: [ { url: "https://newpeer.example.org", scope: "wan", priority: 100 } ]
      }
    end

    it "creates a proposed peer and returns a single-use acceptance token" do
      post base, params: valid_body, headers: auth_headers_for(inviter), as: :json
      expect(response).to have_http_status(:created)

      data = json_response_data
      expect(data["peer"]["status"]).to eq("proposed")
      expect(data["peer"]["peer_kind"]).to eq("platform")
      expect(data["peer"]["acceptance_pending"]).to be true
      expect(data["acceptance_token"]).to be_present
      expect(data["acceptance_token"].length).to be > 16
    end

    it "rejects invalid spawn_role" do
      post base, params: valid_body.merge(spawn_role: "bogus"),
                 headers: auth_headers_for(inviter), as: :json
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects missing remote_instance_url" do
      post base, params: valid_body.except(:remote_instance_url),
                 headers: auth_headers_for(inviter), as: :json
      expect(response).to have_http_status(:bad_request)
    end

    it "forbids without invite permission" do
      post base, params: valid_body, headers: auth_headers_for(reader), as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /peers/:id" do
    let!(:peer) do
      create(:system_federation_peer, :active, account: account,
                                                remote_instance_url: "https://alice.example.org")
    end

    it "returns full detail with allowed_transitions + related counts" do
      get "#{base}/#{peer.id}", headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)

      p = json_response_data["peer"]
      expect(p["id"]).to eq(peer.id)
      expect(p["allowed_transitions"]).to include("degraded")
      expect(p).to include("grants_count", "capabilities_count", "bridges_count")
    end

    it "404s for unknown id" do
      get "#{base}/nonexistent", headers: auth_headers_for(reader)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /peers/:id/revoke" do
    let!(:peer) do
      create(:system_federation_peer, :active, account: account)
    end

    it "transitions peer to revoked" do
      post "#{base}/#{peer.id}/revoke", params: { reason: "test" },
                                         headers: auth_headers_for(manager), as: :json
      expect(response).to have_http_status(:ok)
      expect(json_response_data["peer"]["status"]).to eq("revoked")
    end

    it "409s on second revoke" do
      peer.revoke!(reason: "already revoked")
      post "#{base}/#{peer.id}/revoke", headers: auth_headers_for(manager), as: :json
      expect(response).to have_http_status(:conflict)
    end

    it "forbids without manage permission" do
      post "#{base}/#{peer.id}/revoke", headers: auth_headers_for(reader), as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
