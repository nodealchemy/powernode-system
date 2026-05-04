# frozen_string_literal: true

require "rails_helper"

# Phase 10.7 — peer-as-Agent mirror service.
RSpec.describe System::PeerAgentMirror do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let!(:provider) { ::Ai::Provider.first || create(:ai_provider) }
  let!(:creator) { create(:user, account: account) }
  let(:node) { create(:system_node, account: account, name: "web-01") }
  let(:node_instance) { create(:system_node_instance, node: node, name: "i-aaa") }
  let!(:peer) do
    p = ::System::AgentPeeringService.announce!(
      node_instance: node_instance, capabilities: {}, skills: [], addresses: [ "10.0.0.5" ]
    ).peer
    p.update!(handle: "instance-aaaaaaaa", enabled: true, status: "active")
    p
  end

  describe ".mirror_for_peer!" do
    it "creates a mirror Ai::Agent on first call" do
      agent = described_class.mirror_for_peer!(peer, creator: creator)

      expect(agent).to be_persisted
      expect(agent.account_id).to eq(account.id)
      expect(agent.name).to eq("instance-aaaaaaaa")
      expect(agent.agent_type).to eq("assistant")
      expect(agent.metadata["kind"]).to eq("system_node_peer")
      expect(agent.status).to eq("active")
      expect(agent.metadata["peer_id"]).to eq(peer.id)
      expect(agent.metadata["node_instance_id"]).to eq(node_instance.id)
    end

    it "is idempotent — repeated calls update in place, no duplicates" do
      first = described_class.mirror_for_peer!(peer, creator: creator)
      second = described_class.mirror_for_peer!(peer, creator: creator)

      expect(second.id).to eq(first.id)
      expect(::Ai::Agent.where(account: account, agent_type: "assistant")
        .where("metadata ->> 'kind' = ?", "system_node_peer").count).to eq(1)
    end

    it "updates the description when the peer's node moves" do
      described_class.mirror_for_peer!(peer, creator: creator)
      node.update!(name: "web-renamed")
      agent = described_class.mirror_for_peer!(peer, creator: creator)

      expect(agent.description).to include("web-renamed")
    end

    it "tolerates a missing creator by falling back to the account's oldest user" do
      agent = described_class.mirror_for_peer!(peer, creator: nil)

      expect(agent).to be_persisted
      expect(agent.creator_id).to eq(creator.id)
    end

    it "returns nil when no Ai::Provider is configured" do
      allow(::Ai::Provider).to receive(:first).and_return(nil)

      expect(described_class.mirror_for_peer!(peer, creator: creator)).to be_nil
    end

    it "returns nil when peer is nil" do
      expect(described_class.mirror_for_peer!(nil)).to be_nil
    end
  end

  describe ".archive_for_peer!" do
    before { described_class.mirror_for_peer!(peer, creator: creator) }

    it "sets the mirror agent's status to archived" do
      agent = described_class.archive_for_peer!(peer)

      expect(agent.status).to eq("archived")
    end

    it "returns nil when no mirror exists for the peer" do
      other_node = create(:system_node, account: account)
      other_instance = create(:system_node_instance, node: other_node, name: "i-bbb")
      other_peer = ::System::AgentPeeringService.announce!(
        node_instance: other_instance, capabilities: {}, skills: [], addresses: []
      ).peer

      expect(described_class.archive_for_peer!(other_peer)).to be_nil
    end
  end

  describe ".find_mirror" do
    it "is account-scoped (cross-tenant isolation)" do
      described_class.mirror_for_peer!(peer, creator: creator)

      foreign_node = create(:system_node, account: other_account)
      foreign_instance = create(:system_node_instance, node: foreign_node)
      foreign_peer = ::System::AgentPeeringService.announce!(
        node_instance: foreign_instance, capabilities: {}, skills: [], addresses: []
      ).peer
      # Force the same handle to test scoping
      foreign_peer.update!(handle: "instance-aaaaaaaa")

      expect(described_class.find_mirror(foreign_peer)).to be_nil
    end
  end
end
