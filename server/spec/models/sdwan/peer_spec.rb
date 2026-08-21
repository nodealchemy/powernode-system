# frozen_string_literal: true

require "rails_helper"

# IMP-ee57d0fbe859 — the operator-facing identity seam. Two surfaces name a
# peer on the SAME destructive operation (the approval card served by the
# approvals API, built from PeersController#destroy's `description:`, and the
# notification body built from Sdwan::Executors::DeletePeer#summarize). They
# drifted once already because each carried its own copy of the expression;
# both now consume Peer#operator_label, so a change to identity can only
# happen in one place.
RSpec.describe Sdwan::Peer do
  describe "#operator_label" do
    let(:account) { create(:account) }
    let(:network) { create(:sdwan_network, account: account, name: "wan-core") }

    it "names the node instance and the network it is being removed from" do
      peer = create(:sdwan_peer, :hub, account: account, network: network)
      peer.node_instance.update!(name: "edge-lon-01")

      expect(peer.operator_label).to eq("edge-lon-01 on wan-core")
    end

    it "distinguishes the same instance's peers in different networks" do
      # The unique index is [sdwan_network_id, node_instance_id] (schema:10734),
      # so one instance is legitimately a peer in several networks. Without the
      # network name both cards read identically while deleting different rows.
      other_network = create(:sdwan_network, account: account, name: "wan-edge")
      instance = create(:system_node_instance, name: "edge-lon-01")
      peer_a = create(:sdwan_peer, account: account, network: network, node_instance: instance)
      peer_b = create(:sdwan_peer, account: account, network: other_network, node_instance: instance)

      expect(peer_a.operator_label).to eq("edge-lon-01 on wan-core")
      expect(peer_b.operator_label).to eq("edge-lon-01 on wan-edge")
      expect(peer_a.operator_label).not_to eq(peer_b.operator_label)
    end

    it "falls back to the discovered hostname when the instance is unnamed" do
      peer = create(:sdwan_peer, account: account, network: network)
      # name is NOT NULL, so blank it at the column level rather than through
      # validation — this is the shape a partially-enrolled instance presents.
      peer.node_instance.update_column(:name, "")
      peer.node_instance.update_column(:discovered_hostname, "edge-lon-01.local")

      expect(peer.operator_label).to eq("edge-lon-01.local on wan-core")
    end

    it "falls back to the endpoint when the instance carries no name at all" do
      peer = create(:sdwan_peer, :hub, account: account, network: network)
      peer.node_instance.update_column(:name, "")

      expect(peer.operator_label).to eq("[fd00:abcd:1::1]:51820 on wan-core")
    end

    it "falls back to the bare id only when nothing else identifies the peer" do
      peer = create(:sdwan_peer, account: account, network: network)
      peer.node_instance.update_column(:name, "")

      expect(peer.operator_label).to eq("#{peer.id} on wan-core")
    end
  end

  describe ".format_host_port" do
    # Published class method with live callers outside this model
    # (peers_controller, sdwan_tool, WgConfigRenderer, both topology
    # strategies). IMP-9537a74e50fa moved the body to Sdwan::HostPort; this
    # pins the delegation so the published name keeps its exact semantics.
    it "delegates to the one shared implementation" do
      expect(described_class.format_host_port("fd00::1", 51_820)).to eq("[fd00::1]:51820")
      expect(described_class.format_host_port("[fd00::1]", 51_820)).to eq("[fd00::1]:51820")
      expect(described_class.format_host_port("203.0.113.7", 51_820)).to eq("203.0.113.7:51820")
      expect(described_class.format_host_port("edge.example.net", 51_820)).to eq("edge.example.net:51820")
    end
  end

  describe "#endpoint_display" do
    it "brackets an IPv6 literal so the port stays unambiguous" do
      peer = create(:sdwan_peer, :hub)

      expect(peer.endpoint_display).to eq("[fd00:abcd:1::1]:51820")
    end

    it "does NOT bracket a hostname stored in the v6 column" do
      # endpoint_host_v6_must_be_v6_or_hostname explicitly accepts hostnames
      # (DNS hands back the AAAA), so family == :v6 does not imply a literal.
      # Bracketing on family renders "[edge.example.net]:51820".
      peer = create(:sdwan_peer, :hub, endpoint_host_v6: "edge.example.net")

      expect(peer.endpoint_display).to eq("edge.example.net:51820")
    end

    it "does not double-bracket a host that is already bracketed" do
      # endpoint_host_v6_must_be_v6_or_hostname admits "[fd00::1]" — its literal
      # guard is `include?(":")`, which a bracketed literal satisfies — and
      # WireGuard's own config syntax is `Endpoint = [fd00::1]:51820`, so this is
      # exactly what an operator pastes out of a wg config.
      peer = create(:sdwan_peer, :hub, endpoint_host_v6: "[fd00:abcd:1::1]")

      expect(peer.endpoint_display).to eq("[fd00:abcd:1::1]:51820")
    end

    it "renders a v4 endpoint unbracketed" do
      peer = create(:sdwan_peer, :hub, endpoint_host_v6: nil, endpoint_host_v4: "203.0.113.7")

      expect(peer.endpoint_display).to eq("203.0.113.7:51820")
    end

    it "is nil when the peer has no endpoint" do
      expect(create(:sdwan_peer).endpoint_display).to be_nil
    end
  end
end
