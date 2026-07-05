# frozen_string_literal: true

require "rails_helper"

# Regression coverage for IMP-64684f9a0ae6: Sdwan::VrfAllocator.allocate!
# had zero production callers, so no Sdwan::HostVrfAssignment was ever
# created outside seeds/specs. Every VIP-backed data-plane path (and, on
# iBGP networks, the BGP `router bgp ... vrf` block) reads its VRF name
# from the host's HostVrfAssignment via TopologyCompiler#vrf_name_for —
# with no row, that always resolved to "" and vip_applier.go/config_compiler
# both silently skip empty-VrfName entries. PeerEnroller is the single
# "join a node-instance to a network" seam used by operators, MCP tools,
# and autonomy actions alike, so it's the right place to allocate.
RSpec.describe Sdwan::PeerEnroller, type: :service do
  let(:account) { Account.first || create(:account) }
  let(:node)     { sdwan_test_node(account: account) }
  let(:instance) { sdwan_test_node_instance(node: node) }

  before do
    Sdwan::HostVrfAssignment.where(account_id: account.id).delete_all
    Sdwan::Configuration.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
  end

  let(:network) { Sdwan::Network.create!(account_id: account.id, name: "enroll-net-#{SecureRandom.hex(3)}") }

  describe ".call" do
    it "allocates and activates a HostVrfAssignment for the enrolled (host, network) pair" do
      described_class.call(network: network, node_instance: instance)

      hva = Sdwan::HostVrfAssignment.find_by(node_instance_id: instance.id, sdwan_network_id: network.id)
      expect(hva).to be_present
      expect(hva).to be_active
      expect(hva.vrf_name).to be_present
      expect(hva.table_id).to be_present
    end

    it "makes the VRF name reach the compiled peer view so the VIP data plane can install" do
      peer = described_class.call(network: network, node_instance: instance)

      view = Sdwan::TopologyCompiler.compile_for_peer(peer)
      expect(view[:interface][:vrf_name]).to be_present
    end

    it "reuses the existing HostVrfAssignment when the allocator is invoked again for the same (host, network)" do
      described_class.call(network: network, node_instance: instance)
      first = Sdwan::HostVrfAssignment.find_by(node_instance_id: instance.id, sdwan_network_id: network.id)

      again = Sdwan::VrfAllocator.allocate!(host: instance, network: network)

      expect(again.id).to eq(first.id)
      expect(Sdwan::HostVrfAssignment.where(node_instance_id: instance.id, sdwan_network_id: network.id).count).to eq(1)
    end

    it "assigns each enrolled host its own HostVrfAssignment on a shared network (table_ids are per-host, not global)" do
      other_instance = sdwan_test_node_instance(node: node)

      described_class.call(network: network, node_instance: instance)
      described_class.call(network: network, node_instance: other_instance)

      hvas = Sdwan::HostVrfAssignment.where(sdwan_network_id: network.id)
      expect(hvas.count).to eq(2)
      expect(hvas.pluck(:node_instance_id)).to contain_exactly(instance.id, other_instance.id)
      expect(hvas).to all(be_active)
    end
  end
end
