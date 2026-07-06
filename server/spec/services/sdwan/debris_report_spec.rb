# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::DebrisReport do
  let(:account) { create(:account) }

  describe ".call — Sdwan::Network classification" do
    it "classifies a network with zero peers as safe_to_delete" do
      network = create(:sdwan_network, account: account)

      row = described_class.call.find { |r| r.kind == "Sdwan::Network" && r.id == network.id }

      expect(row.safe_to_delete).to be(true)
      expect(row.reason).to match(/no live peer/)
    end

    it "classifies a network whose only peer is on a terminated instance as safe_to_delete" do
      network = create(:sdwan_network, account: account)
      dead_instance = create(:system_node_instance, account: account, status: "terminated")
      create(:sdwan_peer, account: account, network: network, node_instance: dead_instance)

      row = described_class.call.find { |r| r.kind == "Sdwan::Network" && r.id == network.id }

      expect(row.safe_to_delete).to be(true)
    end

    it "classifies a network with a live (non-terminated) peer as keep" do
      network = create(:sdwan_network, account: account)
      live_instance = create(:system_node_instance, account: account, status: "running")
      create(:sdwan_peer, account: account, network: network, node_instance: live_instance)

      row = described_class.call.find { |r| r.kind == "Sdwan::Network" && r.id == network.id }

      expect(row.safe_to_delete).to be(false)
      expect(row.reason).to match(/LIVE/)
    end

    it "includes the destroy call and peer count in the label" do
      network = create(:sdwan_network, account: account)

      row = described_class.call.find { |r| r.kind == "Sdwan::Network" && r.id == network.id }

      expect(row.destroy_code).to eq(
        "::Sdwan::Network.find(#{network.id.inspect}).destroy!  " \
        "# cascades peers/keys/firewall_rules/virtual_ips/port_mappings/" \
        "subnet_advertisements/host_vrf_assignments"
      )
      expect(row.label).to include("peers=0")
    end
  end

  describe ".call — Sdwan::Peer classification" do
    it "classifies a peer on a terminated instance as safe_to_delete" do
      network = create(:sdwan_network, account: account)
      dead_instance = create(:system_node_instance, account: account, status: "terminated")
      peer = create(:sdwan_peer, account: account, network: network, node_instance: dead_instance)

      row = described_class.call.find { |r| r.kind == "Sdwan::Peer" && r.id == peer.id }

      expect(row.safe_to_delete).to be(true)
      expect(row.reason).to eq("node_instance terminated")
    end

    it "classifies a peer on a live instance as keep" do
      network = create(:sdwan_network, account: account)
      live_instance = create(:system_node_instance, account: account, status: "running")
      peer = create(:sdwan_peer, account: account, network: network, node_instance: live_instance)

      row = described_class.call.find { |r| r.kind == "Sdwan::Peer" && r.id == peer.id }

      expect(row.safe_to_delete).to be(false)
      expect(row.reason).to eq("node_instance still running")
    end
  end

  describe ".call — System::FederationPeer classification" do
    it "classifies a revoked federation peer as safe_to_delete" do
      fp = create(:system_federation_peer, account: account, status: "revoked")

      row = described_class.call.find { |r| r.kind == "System::FederationPeer" && r.id == fp.id }

      expect(row.safe_to_delete).to be(true)
      expect(row.reason).to match(/terminal/)
    end

    it "classifies a non-terminal federation peer as keep" do
      fp = create(:system_federation_peer, account: account, status: "accepted")

      row = described_class.call.find { |r| r.kind == "System::FederationPeer" && r.id == fp.id }

      expect(row.safe_to_delete).to be(false)
      expect(row.reason).to match(/not terminal/)
    end
  end

  describe ".call — no mutation" do
    it "performs zero writes (read-only enumeration)" do
      network = create(:sdwan_network, account: account)

      expect { described_class.call }
        .not_to change { network.reload.updated_at }
    end
  end
end
