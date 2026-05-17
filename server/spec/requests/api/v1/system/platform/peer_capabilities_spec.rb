# frozen_string_literal: true

require "rails_helper"

# Plan reference: Decentralized Federation §D + §I + P4 + P7.6.
RSpec.describe "Api::V1::System::Platform::PeerCapabilities", type: :request do
  let(:account) { create(:account) }
  let(:reader)  { user_with_permissions("system.peers.read", account: account) }
  let(:manager) { user_with_permissions("system.peers.read", "system.peers.manage", account: account) }
  let!(:peer) do
    create(:system_federation_peer, :active, account: account)
  end
  let(:base) { "/api/v1/system/platform/peers/#{peer.id}/capabilities" }

  describe "GET /capabilities" do
    let!(:cap_a) do
      create(:system_federation_capability, account: account, federation_peer: peer,
                                             resource_kind: "skill",
                                             direction: "push_local_to_remote",
                                             policy: "manual")
    end
    let!(:cap_b) do
      create(:system_federation_capability, account: account, federation_peer: peer,
                                             resource_kind: "trading_strategy",
                                             direction: "bidirectional",
                                             policy: "auto_on_change")
    end

    it "lists capabilities for this peer ordered by kind+direction" do
      get base, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)

      data = json_response_data
      expect(data["count"]).to eq(2)
      expect(data["capabilities"].map { |c| c["resource_kind"] }).to eq(%w[skill trading_strategy])
    end

    it "forbids without read permission" do
      anon = create(:user, account: account)
      get base, headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /capabilities" do
    let(:valid_body) do
      {
        resource_kind: "skill",
        direction: "push_local_to_remote",
        policy: "manual",
        filter: { "tags" => [ "public" ] },
        conflict_resolution: "local_wins"
      }
    end

    it "creates a capability with filter JSON intact" do
      post base, params: valid_body, headers: auth_headers_for(manager), as: :json
      expect(response).to have_http_status(:created)

      cap = json_response_data["capability"]
      expect(cap["resource_kind"]).to eq("skill")
      expect(cap["direction"]).to eq("push_local_to_remote")
      expect(cap["filter"]).to eq("tags" => [ "public" ])
    end

    it "rejects invalid direction" do
      post base, params: valid_body.merge(direction: "sideways"),
                 headers: auth_headers_for(manager), as: :json
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects invalid policy" do
      post base, params: valid_body.merge(policy: "fast"),
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

  describe "DELETE /capabilities/:id" do
    let!(:cap) do
      create(:system_federation_capability, account: account, federation_peer: peer,
                                             resource_kind: "skill",
                                             direction: "push_local_to_remote")
    end

    it "hard-deletes" do
      delete "#{base}/#{cap.id}", headers: auth_headers_for(manager)
      expect(response).to have_http_status(:ok)
      expect(::System::FederationCapability.where(id: cap.id)).to be_empty
    end

    it "forbids without manage permission" do
      delete "#{base}/#{cap.id}", headers: auth_headers_for(reader)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
