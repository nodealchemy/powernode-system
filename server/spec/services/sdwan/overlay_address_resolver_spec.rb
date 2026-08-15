# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::OverlayAddressResolver, type: :service do
  let(:account)  { Account.first || create(:account) }
  let(:node)     { sdwan_test_node(account: account) }
  let(:instance) { sdwan_test_node_instance(node: node) }
  let(:network)  { create(:sdwan_network, account: account) }

  # A peer is UNIQUE on (sdwan_network_id, node_instance_id), so an
  # instance can only hold several peers by being multi-homed across
  # several networks — which is exactly the case the `order(:created_at)`
  # tail in the original queries was picking between.
  def peer_for(inst, created_at: nil, net: network)
    peer = create(:sdwan_peer, account: account, network: net, node_instance: inst)
    peer.update_column(:created_at, created_at) if created_at
    peer
  end

  describe ".addressed_peer_for" do
    it "returns the oldest peer carrying an assigned overlay address" do
      newer = peer_for(instance, created_at: 1.day.ago)
      older = peer_for(instance, created_at: 3.days.ago,
                       net: create(:sdwan_network, account: account))

      expect(described_class.addressed_peer_for(instance)).to eq(older)
      expect(described_class.addressed_peer_for(instance)).not_to eq(newer)
    end

    it "returns nil when the instance has no peer" do
      expect(described_class.addressed_peer_for(instance)).to be_nil
    end

    it "does not leak a peer belonging to a different node instance" do
      other = sdwan_test_node_instance(node: node)
      peer_for(other)

      expect(described_class.addressed_peer_for(instance)).to be_nil
    end
  end

  describe ".address_for" do
    # The three callers that previously inlined this query all stripped
    # the prefix length before use: `assigned_address` is stored in CIDR
    # form and neither a Docker URL host nor an OVN encap IP tolerates a
    # trailing `/128`.
    it "strips the CIDR prefix length from the assigned address" do
      peer = peer_for(instance)
      # Pin against an address that ACTUALLY carries a prefix length and
      # assert the literal stripped value. The factory's sequence has no
      # "/" in it, so asserting `split("/").first` of the factory value
      # would restate the implementation and stay green even with the
      # strip deleted — while DockerDaemonProvisionerService would build
      # `tcp://[fd00:abcd:1::9/128]:2376` and every daemon call would fail.
      peer.update_column(:assigned_address, "fd00:abcd:1::9/128")

      expect(described_class.address_for(instance)).to eq("fd00:abcd:1::9")
    end

    it "returns nil when the instance has no peer, rather than raising" do
      # Callers own their own error type (each raises a differently-named
      # MissingSdwanPeerError that its own callers rescue by class), so the
      # seam reports absence as nil and never raises.
      expect(described_class.address_for(instance)).to be_nil
    end

    it "resolves the address of the oldest peer when several are attached" do
      older = peer_for(instance, created_at: 3.days.ago)
      peer_for(instance, created_at: 1.day.ago,
               net: create(:sdwan_network, account: account))

      expect(described_class.address_for(instance))
        .to eq(older.assigned_address.to_s.split("/").first)
    end
  end

  describe ".attachment_peer_for" do
    # RuntimeConfigBuilder wants the peer's *network* (to derive the
    # flannel interface name), not its address, and never ordered its
    # lookup. Kept as a separate entry point so the ordering difference
    # stays visible instead of being silently unified.
    it "returns a peer attached to the instance" do
      peer = peer_for(instance)

      expect(described_class.attachment_peer_for(instance)).to eq(peer)
    end

    it "returns nil when the instance has no peer" do
      expect(described_class.attachment_peer_for(instance)).to be_nil
    end

    it "does not leak a peer belonging to a different node instance" do
      other = sdwan_test_node_instance(node: node)
      peer_for(other)

      expect(described_class.attachment_peer_for(instance)).to be_nil
    end
  end

  # The eighth migrated call site had NO spec of its own. Its "" (never
  # nil) return is the subtle part of routing it through the seam — the
  # agent's OvnControllerApplier tests for an empty string to decide
  # whether to skip ovn-controller startup, so a nil leaking through
  # would change on-node behavior rather than just a return type.
  describe "Sdwan::TopologyCompiler.derive_sdwan_encap_ip (migrated caller)" do
    it "returns the stripped overlay address for an attached host" do
      peer = peer_for(instance)
      peer.update_column(:assigned_address, "fd00:abcd:1::7/128")

      expect(Sdwan::TopologyCompiler.derive_sdwan_encap_ip(instance))
        .to eq("fd00:abcd:1::7")
    end

    it "returns an empty string, never nil, for a host with no peer" do
      result = Sdwan::TopologyCompiler.derive_sdwan_encap_ip(instance)

      expect(result).to eq("")
      expect(result).not_to be_nil
    end
  end
end
