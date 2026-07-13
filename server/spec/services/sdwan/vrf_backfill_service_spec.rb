# frozen_string_literal: true

require "rails_helper"

# IMP-07014982a6d3: IMP-64684f9a0ae6 (commit 3bd50ff) wired VrfAllocator
# into PeerEnroller, but only enrollment (Sdwan::Peer creation) triggers
# it. Peers created before that fix — or any row inserted without going
# through PeerEnroller — have no HostVrfAssignment, so their VIPs still
# black-hole and iBGP still has no `router bgp vrf` block, exactly the
# failure IMP-64684f9a0ae6 fixed for new enrollments. VrfBackfillService
# is the one-time (idempotent — safe to re-run) backfill for those rows.
RSpec.describe Sdwan::VrfBackfillService, type: :service do
  let(:account) { Account.first || create(:account) }
  let(:node)     { sdwan_test_node(account: account) }
  let(:instance) { sdwan_test_node_instance(node: node) }
  let(:network) { Sdwan::Network.create!(account_id: account.id, name: "backfill-net-#{SecureRandom.hex(3)}") }

  before do
    Sdwan::HostVrfAssignment.where(account_id: account.id).delete_all
  end

  describe ".call" do
    it "allocates and activates a HostVrfAssignment for a pre-existing peer that has none" do
      Sdwan::Peer.create!(network: network, node_instance: instance, account_id: account.id, listen_port: 51_820)
      expect(Sdwan::HostVrfAssignment.where(node_instance_id: instance.id, sdwan_network_id: network.id)).not_to exist

      result = described_class.call

      hva = Sdwan::HostVrfAssignment.find_by(node_instance_id: instance.id, sdwan_network_id: network.id)
      expect(hva).to be_present
      expect(hva).to be_active
      expect(hva.vrf_name).to be_present
      expect(result.backfilled_count).to eq(1)
      expect(result.errors).to be_empty
    end

    it "is idempotent — re-running after a successful backfill does nothing further" do
      Sdwan::Peer.create!(network: network, node_instance: instance, account_id: account.id, listen_port: 51_820)
      described_class.call

      result = described_class.call

      expect(result.backfilled_count).to eq(0)
      expect(Sdwan::HostVrfAssignment.where(node_instance_id: instance.id, sdwan_network_id: network.id).count).to eq(1)
    end

    it "does not touch peers that already have a HostVrfAssignment (enrolled via PeerEnroller post-fix)" do
      Sdwan::PeerEnroller.call(network: network, node_instance: instance)
      existing = Sdwan::HostVrfAssignment.find_by(node_instance_id: instance.id, sdwan_network_id: network.id)

      result = described_class.call

      expect(Sdwan::HostVrfAssignment.where(node_instance_id: instance.id, sdwan_network_id: network.id).count).to eq(1)
      expect(Sdwan::HostVrfAssignment.find(existing.id).updated_at).to eq(existing.updated_at)
      expect(result.backfilled_count).to eq(0)
    end

    it "backfills regardless of the peer's handshake status (pending peers still need a VRF for BGP/VIP config)" do
      peer = Sdwan::Peer.create!(network: network, node_instance: instance, account_id: account.id, listen_port: 51_820)
      expect(peer.status).to eq("pending")

      result = described_class.call

      expect(result.backfilled_count).to eq(1)
      expect(Sdwan::HostVrfAssignment.where(node_instance_id: instance.id, sdwan_network_id: network.id)).to exist
    end

    it "records a per-peer error and keeps going when one allocation fails" do
      other_instance = sdwan_test_node_instance(node: node)
      other_network = Sdwan::Network.create!(account_id: account.id, name: "backfill-net-b-#{SecureRandom.hex(3)}")
      peer_a = Sdwan::Peer.create!(network: network, node_instance: instance, account_id: account.id, listen_port: 51_820)
      Sdwan::Peer.create!(network: other_network, node_instance: other_instance, account_id: account.id, listen_port: 51_820)

      allow(Sdwan::VrfAllocator).to receive(:allocate_and_activate!).and_call_original
      allow(Sdwan::VrfAllocator).to receive(:allocate_and_activate!)
        .with(host: peer_a.node_instance, network: peer_a.network)
        .and_raise(Sdwan::VrfAllocator::CapacityExhausted, "no free table_id")

      result = described_class.call

      expect(result.backfilled_count).to eq(1)
      expect(result.errors.size).to eq(1)
      expect(result.errors.first).to include(peer_a.id)
      expect(Sdwan::HostVrfAssignment.where(node_instance_id: other_instance.id, sdwan_network_id: other_network.id)).to exist
    end
  end
end
