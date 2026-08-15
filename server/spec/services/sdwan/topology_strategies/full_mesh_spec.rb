# frozen_string_literal: true

require "rails_helper"

# Full-mesh topology strategy: every peer connects directly to every OTHER
# peer (no hub relay). Mirrors the test idiom in
# spec/services/sdwan/topology_compiler_spec.rb — peers are enrolled via the
# real Sdwan::PeerEnroller (which generates keys), then we assert on the
# strategy's per-peer view.
RSpec.describe Sdwan::TopologyStrategies::FullMesh, type: :service do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::Network.where(account_id: account.id).delete_all
  end

  # full_mesh networks resolve this strategy via settings["topology_strategy"].
  let!(:network) do
    Sdwan::Network.create!(account_id: account.id, name: "mesh-net-#{SecureRandom.hex(4)}",
                           settings: { "topology_strategy" => "full_mesh" })
  end

  let!(:node) { create(:system_node, account: account, name: "mesh-node-#{SecureRandom.hex(4)}") }
  let!(:instance_a) { create(:system_node_instance, node: node, name: "a-#{SecureRandom.hex(2)}") }
  let!(:instance_b) { create(:system_node_instance, node: node, name: "b-#{SecureRandom.hex(2)}") }
  let!(:instance_c) { create(:system_node_instance, node: node, name: "c-#{SecureRandom.hex(2)}") }

  # Peer A advertises a public endpoint; B and C are reached outbound.
  let!(:peer_a) do
    Sdwan::PeerEnroller.call(
      network: network, node_instance: instance_a,
      publicly_reachable: true, endpoint_host: "203.0.113.10", endpoint_port: 51_820
    )
  end
  let!(:peer_b) { Sdwan::PeerEnroller.call(network: network, node_instance: instance_b) }
  let!(:peer_c) { Sdwan::PeerEnroller.call(network: network, node_instance: instance_c) }

  subject(:strategy) { described_class.new(network: network.reload) }

  describe "#peers_for" do
    it "gives every peer a direct entry for every OTHER peer (full mesh, N-1)" do
      view = strategy.peers_for(peer_a.reload)
      expect(view.map { |e| e[:peer_id] }).to contain_exactly(peer_b.id, peer_c.id)

      view_b = strategy.peers_for(peer_b.reload)
      expect(view_b.map { |e| e[:peer_id] }).to contain_exactly(peer_a.id, peer_c.id)
    end

    it "advertises each sibling's own /128 — never the whole /64 (no hub relay)" do
      view = strategy.peers_for(peer_a.reload)
      entry_b = view.find { |e| e[:peer_id] == peer_b.id }

      expect(entry_b[:allowed_ips]).to eq([ peer_b.assigned_address ])
      expect(entry_b[:allowed_ips]).not_to include(network.cidr_64)
      expect(entry_b[:public_key]).to eq(peer_b.active_key.public_key)
    end

    it "sets persistent_keepalive only toward publicly_reachable siblings" do
      # From a spoke's perspective: keepalive toward the public peer (A),
      # none toward the other non-public peer (C).
      view = strategy.peers_for(peer_b.reload)
      toward_a = view.find { |e| e[:peer_id] == peer_a.id }
      toward_c = view.find { |e| e[:peer_id] == peer_c.id }

      expect(toward_a[:persistent_keepalive]).to eq(described_class::DEFAULT_PERSISTENT_KEEPALIVE)
      expect(toward_a[:endpoint]).to eq("203.0.113.10:51820")
      expect(toward_c[:persistent_keepalive]).to be_nil
    end

    it "excludes the peer's own entry from its view" do
      view = strategy.peers_for(peer_a.reload)
      expect(view.map { |e| e[:peer_id] }).not_to include(peer_a.id)
    end

    it "skips siblings whose only key is revoked" do
      peer_c.active_key.update!(revoked_at: Time.current)
      view = strategy.peers_for(peer_a.reload)
      expect(view.map { |e| e[:peer_id] }).to contain_exactly(peer_b.id)
    end
  end

  describe "static-mode subnet fold-in" do
    it "folds a sibling's lan_subnets into the AllowedIPs that route to it" do
      peer_b.update!(lan_subnets: [ "10.50.0.0/16" ])
      view = described_class.new(network: network.reload).peers_for(peer_a.reload)
      entry_b = view.find { |e| e[:peer_id] == peer_b.id }

      expect(entry_b[:allowed_ips]).to include(peer_b.assigned_address, "10.50.0.0/16")
    end
  end

  describe "VIP fold-in (slice 9b)" do
    it "routes a VIP's CIDR directly to its holder peer in static mode" do
      vip = ::Sdwan::VirtualIp.create!(
        account_id: account.id, sdwan_network_id: network.id,
        name: "mesh-vip", cidr: "fd00:abcd:ffff::1/128",
        holder_peer_ids: [ peer_c.id ], state: "active"
      )
      view = described_class.new(network: network.reload).peers_for(peer_a.reload)
      entry_c = view.find { |e| e[:peer_id] == peer_c.id }

      expect(entry_c[:allowed_ips]).to include(vip.cidr)
    end
  end

  # IMP-d182a8e6e19c — the compiled entry's :endpoint feeds `wg setconf`
  # verbatim (agent/internal/sdwan/state.go → wg_applier.go), so a v6
  # literal MUST be bracketed. Peer A's v4 assertion above
  # ("203.0.113.10:51820") is the positive twin pinning v4 stays bare.
  describe "IPv6-literal endpoint bracketing" do
    let!(:instance_d) { create(:system_node_instance, node: node, name: "d-#{SecureRandom.hex(2)}") }
    let!(:peer_d) do
      Sdwan::PeerEnroller.call(
        network: network, node_instance: instance_d,
        publicly_reachable: true, endpoint_host_v6: "fd00:abcd:2::1", endpoint_port: 51_820
      )
    end

    it "brackets a sibling's v6-literal endpoint in the compiled entry" do
      view = described_class.new(network: network.reload).peers_for(peer_b.reload)
      entry_d = view.find { |e| e[:peer_id] == peer_d.id }

      expect(entry_d[:endpoint_family]).to eq("v6")
      expect(entry_d[:endpoint]).to eq("[fd00:abcd:2::1]:51820")
    end
  end

  describe "user devices (slice 4)" do
    it "includes active user_devices as endpoint-less, keepalive-less peers" do
      grant = create(:sdwan_access_grant, account: account, network: network)
      device = create(:sdwan_user_device, access_grant: grant)

      view = described_class.new(network: network.reload).peers_for(peer_a.reload)
      device_entry = view.find { |e| e[:peer_id] == device.id }

      expect(device_entry).to be_present
      expect(device_entry[:kind]).to eq("user_device")
      expect(device_entry[:endpoint]).to be_nil
      expect(device_entry[:persistent_keepalive]).to be_nil
      expect(device_entry[:allowed_ips]).to eq([ device.assigned_address ])
    end
  end

  describe "integration through Sdwan::TopologyCompiler" do
    it "is resolved by the compiler from settings[topology_strategy]=full_mesh" do
      # compile_for_peer dispatches via strategy_for → FullMesh. A successful
      # compile with N-1 peer entries proves the wiring end-to-end.
      view = ::Sdwan::TopologyCompiler.compile_for_peer(peer_a.reload)
      expect(view[:peers].map { |e| e[:peer_id] }).to contain_exactly(peer_b.id, peer_c.id)
    end
  end
end
