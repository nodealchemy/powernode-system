# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::TopologyCompiler, type: :service do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::Configuration.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
  end

  let!(:network) { Sdwan::Network.create!(account_id: account.id, name: "compile-net-#{SecureRandom.hex(4)}") }

  # Two NodeInstances under the same account so peers can attach. We
  # bypass full instance setup and just stub the minimum.
  let!(:node) { ::System::Node.create!(account: account, name: "compile-node-#{SecureRandom.hex(4)}") }
  let!(:hub_instance)   { ::System::NodeInstance.create!(node: node, name: "hub-#{SecureRandom.hex(2)}") }
  let!(:spoke_instance) { ::System::NodeInstance.create!(node: node, name: "spoke-#{SecureRandom.hex(2)}") }

  describe "hub-and-spoke topology" do
    let!(:hub_peer) do
      Sdwan::PeerEnroller.call(
        network: network,
        node_instance: hub_instance,
        publicly_reachable: true,
        endpoint_host: "203.0.113.10",
        endpoint_port: 51820
      )
    end

    let!(:spoke_peer) do
      Sdwan::PeerEnroller.call(
        network: network,
        node_instance: spoke_instance,
        publicly_reachable: false
      )
    end

    it "emits a hub view that lists every other peer with its /128 AllowedIP" do
      view = described_class.compile_for_peer(hub_peer)
      expect(view[:peer_id]).to eq(hub_peer.id)
      expect(view[:peers].size).to eq(1)
      spoke_view = view[:peers].first
      expect(spoke_view[:public_key]).to eq(spoke_peer.active_key.public_key)
      expect(spoke_view[:allowed_ips]).to eq([spoke_peer.assigned_address])
    end

    it "emits a spoke view that lists only the hub with the full /64 in AllowedIPs" do
      view = described_class.compile_for_peer(spoke_peer)
      expect(view[:peers].size).to eq(1)
      hub_view = view[:peers].first
      expect(hub_view[:public_key]).to eq(hub_peer.active_key.public_key)
      expect(hub_view[:allowed_ips]).to eq([network.cidr_64])
      expect(hub_view[:endpoint]).to eq("203.0.113.10:51820")
      expect(hub_view[:persistent_keepalive]).to eq(25)
    end

    it "omits private_key from the operator-facing topology endpoint" do
      view = described_class.compile_for_peer(hub_peer, include_private_key: false)
      expect(view[:interface]).not_to have_key(:private_key)
      expect(view[:interface]).to have_key(:public_key)
    end

    it "inlines the private key on the node-API path when include_private_key: true" do
      view = described_class.compile_for_peer(hub_peer, include_private_key: true)
      # private_key may be nil if Vault isn't running in the test env, but
      # the key MUST be present in the hash (i.e. the path was taken).
      expect(view[:interface]).to have_key(:private_key)
    end

    it "emits an empty peers list for a spoke when the network has no hub" do
      Sdwan::Peer.where(sdwan_network_id: network.id, publicly_reachable: true).destroy_all
      view = described_class.compile_for_peer(spoke_peer.reload)
      expect(view[:peers]).to be_empty
    end
  end

  describe "compile_for_network" do
    it "returns one view per peer in the network" do
      Sdwan::PeerEnroller.call(
        network: network, node_instance: hub_instance,
        publicly_reachable: true, endpoint_host: "203.0.113.10", endpoint_port: 51820
      )
      Sdwan::PeerEnroller.call(network: network, node_instance: spoke_instance)
      views = described_class.compile_for_network(network)
      expect(views.size).to eq(2)
    end
  end
end
