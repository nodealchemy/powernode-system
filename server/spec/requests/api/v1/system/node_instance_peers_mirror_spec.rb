# frozen_string_literal: true

require "rails_helper"

# Phase 10.7 — verifies the controller's #activate / #deactivate actions
# correctly call System::PeerAgentMirror.
#
# This is the integration surface the unit-level peer_agent_mirror_spec
# can't reach: the actual HTTP path through NodeInstancePeersController.
RSpec.describe "Api::V1::System::NodeInstancePeers — mirror integration", type: :request do
  let(:account) { create(:account) }
  let!(:provider) { ::Ai::Provider.first || create(:ai_provider) }
  let(:user) { user_with_permissions("system.peers.activate", account: account) }
  let(:headers) { auth_headers_for(user) }
  let(:node) { create(:system_node, account: account, name: "web-01") }
  let(:node_instance) { create(:system_node_instance, node: node, name: "i-aaa") }
  let!(:peer) do
    p = ::System::AgentPeeringService.announce!(
      node_instance: node_instance, capabilities: {}, skills: [], addresses: [ "10.0.0.5" ]
    ).peer
    p.update!(handle: "instance-aaaaaaaa", enabled: false, status: "registered")
    p
  end

  describe "POST /api/v1/system/node_instance_peers/:id/activate" do
    it "creates the mirror Ai::Agent on activation" do
      expect {
        post "/api/v1/system/node_instance_peers/#{peer.id}/activate", headers: headers
      }.to change { ::System::PeerAgentMirror.find_mirror(peer.reload).present? }.from(false).to(true)

      expect(response).to have_http_status(:ok)
      mirror = ::System::PeerAgentMirror.find_mirror(peer)
      expect(mirror.account_id).to eq(account.id)
      expect(mirror.name).to eq("instance-aaaaaaaa")
      expect(mirror.creator_id).to eq(user.id)
      expect(mirror.status).to eq("active")
    end

    it "is idempotent — re-activating doesn't duplicate the mirror" do
      post "/api/v1/system/node_instance_peers/#{peer.id}/activate", headers: headers
      first_id = ::System::PeerAgentMirror.find_mirror(peer.reload).id

      # Force back to disabled and re-activate
      peer.update!(enabled: false, status: "registered")
      post "/api/v1/system/node_instance_peers/#{peer.id}/activate", headers: headers
      second_id = ::System::PeerAgentMirror.find_mirror(peer.reload).id

      expect(second_id).to eq(first_id)
    end
  end

  describe "POST /api/v1/system/node_instance_peers/:id/deactivate" do
    before do
      post "/api/v1/system/node_instance_peers/#{peer.id}/activate", headers: headers
    end

    it "archives the mirror agent on deactivation" do
      post "/api/v1/system/node_instance_peers/#{peer.id}/deactivate", headers: headers

      expect(response).to have_http_status(:ok)
      mirror = ::System::PeerAgentMirror.find_mirror(peer.reload)
      expect(mirror).to be_present
      expect(mirror.status).to eq("archived")
    end

    it "re-activating reuses the archived mirror (status flips back to active)" do
      post "/api/v1/system/node_instance_peers/#{peer.id}/deactivate", headers: headers
      post "/api/v1/system/node_instance_peers/#{peer.id}/activate", headers: headers

      mirror = ::System::PeerAgentMirror.find_mirror(peer.reload)
      expect(mirror.status).to eq("active")
    end
  end
end
