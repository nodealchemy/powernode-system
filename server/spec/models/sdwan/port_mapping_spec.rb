# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::PortMapping, type: :model do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::PortMapping.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
    Sdwan::Configuration.where(account_id: account.id).delete_all
  end

  let!(:network) { Sdwan::Network.create!(account_id: account.id, name: "pm-net-#{SecureRandom.hex(3)}") }
  let!(:node) { sdwan_test_node(account: account) }
  let!(:inst1) { sdwan_test_node_instance(node: node) }
  let!(:inst2) { sdwan_test_node_instance(node: node) }
  let!(:hub) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst1,
                        publicly_reachable: true, endpoint_host_v6: "2001:db8::1", endpoint_port: 51820)
  end
  let!(:target) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst2,
                        publicly_reachable: false)
  end

  describe "validations" do
    it "rejects mapping with neither target_peer nor target_virtual_ip set" do
      m = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                              sdwan_peer_id: hub.id, name: "no-target",
                              listen_port: 5432, protocol: "tcp")
      expect(m).not_to be_valid
      expect(m.errors[:base].join).to match(/exactly one of target_peer_id or target_virtual_ip_id/)
    end

    it "rejects mapping with both targets set" do
      vip = Sdwan::VirtualIp.create!(account_id: account.id, sdwan_network_id: network.id,
                                     name: "vip-#{SecureRandom.hex(2)}", cidr: "192.0.2.50/32",
                                     holder_peer_ids: [target.id], state: "active")
      m = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                              sdwan_peer_id: hub.id, target_peer_id: target.id,
                              target_virtual_ip_id: vip.id, name: "double",
                              listen_port: 5432, protocol: "tcp")
      expect(m).not_to be_valid
      expect(m.errors[:base].join).to match(/exactly one/)
    end

    it "enforces (hub, listen_port, protocol) uniqueness" do
      described_class.create!(account_id: account.id, sdwan_network_id: network.id,
                              sdwan_peer_id: hub.id, target_peer_id: target.id,
                              name: "first", listen_port: 5432, protocol: "tcp")
      dupe = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "dupe", listen_port: 5432, protocol: "tcp")
      expect(dupe).not_to be_valid
      expect(dupe.errors[:sdwan_peer_id]).to include("has already been taken")
    end

    it "allows different protocols on the same (hub, listen_port)" do
      described_class.create!(account_id: account.id, sdwan_network_id: network.id,
                              sdwan_peer_id: hub.id, target_peer_id: target.id,
                              name: "tcp-svc", listen_port: 5432, protocol: "tcp")
      udp = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                                sdwan_peer_id: hub.id, target_peer_id: target.id,
                                name: "udp-svc", listen_port: 5432, protocol: "udp")
      expect(udp).to be_valid
    end

    it "rejects targets in a different network" do
      other_net = Sdwan::Network.create!(account_id: account.id, name: "other-pm-#{SecureRandom.hex(3)}")
      foreign = Sdwan::Peer.create!(account: account, sdwan_network_id: other_net.id,
                                    node_instance: inst2, publicly_reachable: false)
      m = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                              sdwan_peer_id: hub.id, target_peer_id: foreign.id,
                              name: "cross-net", listen_port: 5432, protocol: "tcp")
      expect(m).not_to be_valid
      expect(m.errors[:target_peer_id].join).to match(/same network/)
    end
  end

  describe "#effective_target_port" do
    it "returns target_port when set" do
      m = described_class.new(listen_port: 5432, target_port: 6432)
      expect(m.effective_target_port).to eq(6432)
    end

    it "falls back to listen_port when target_port is nil" do
      m = described_class.new(listen_port: 5432, target_port: nil)
      expect(m.effective_target_port).to eq(5432)
    end
  end

  describe "#resolved_target_address" do
    it "strips the /128 suffix from the target peer's overlay address" do
      m = described_class.create!(account_id: account.id, sdwan_network_id: network.id,
                                  sdwan_peer_id: hub.id, target_peer_id: target.id,
                                  name: "addr-test", listen_port: 22, protocol: "tcp")
      expect(m.resolved_target_address).to eq(target.assigned_address.split("/").first)
    end
  end
end
