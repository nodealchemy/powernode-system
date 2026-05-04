# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::NatCompiler, type: :service do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::PortMapping.where(account_id: account.id).destroy_all
    Sdwan::Network.where(account_id: account.id).destroy_all
    Sdwan::Configuration.where(account_id: account.id).destroy_all
  end

  let!(:network) { Sdwan::Network.create!(account_id: account.id, name: "nat-net-#{SecureRandom.hex(3)}") }
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

  describe "empty output when no port mappings" do
    it "returns zero rules and a nil ruleset" do
      out = described_class.compile_for_peer(hub)
      expect(out[:rule_count]).to eq(0)
      expect(out[:ruleset]).to be_nil
    end
  end

  describe "with one tcp mapping" do
    before do
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "db", listen_port: 5432, protocol: "tcp")
    end

    it "emits one DNAT rule with bracketed v6 destination" do
      out = described_class.compile_for_peer(hub)
      expect(out[:rule_count]).to eq(1)
      addr = target.assigned_address.split("/").first
      expect(out[:ruleset]).to include("tcp dport 5432 dnat to [#{addr}]:5432")
    end

    it "names the chain sdwan_nat_<8-char-net-id>" do
      out = described_class.compile_for_peer(hub)
      short_id = network.id.to_s.delete("-").first(8)
      expect(out[:chain]).to eq("sdwan_nat_#{short_id}")
    end

    it "uses prerouting priority -100" do
      out = described_class.compile_for_peer(hub)
      expect(out[:ruleset]).to include("type nat hook prerouting priority -100")
    end
  end

  describe "with both tcp+udp on the same port" do
    before do
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "tcp-svc", listen_port: 53, protocol: "tcp")
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "udp-svc", listen_port: 53, protocol: "udp")
    end

    it "emits two distinct DNAT rules" do
      out = described_class.compile_for_peer(hub)
      expect(out[:rule_count]).to eq(2)
      expect(out[:ruleset]).to include("tcp dport 53 dnat to")
      expect(out[:ruleset]).to include("udp dport 53 dnat to")
    end
  end

  describe "with target_virtual_ip" do
    let!(:vip) do
      Sdwan::VirtualIp.create!(account_id: account.id, sdwan_network_id: network.id,
                               name: "db-vip", cidr: "192.0.2.50/32",
                               holder_peer_ids: [target.id], state: "active")
    end

    before do
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_virtual_ip_id: vip.id,
                                 name: "vip-published", listen_port: 5432, protocol: "tcp")
    end

    it "resolves DNAT target to the VIP's CIDR (no brackets for v4)" do
      out = described_class.compile_for_peer(hub)
      expect(out[:ruleset]).to include("tcp dport 5432 dnat to 192.0.2.50:5432")
    end
  end

  describe "skips mappings with unresolvable targets" do
    let!(:unassigned_vip) do
      Sdwan::VirtualIp.create!(account_id: account.id, sdwan_network_id: network.id,
                               name: "no-holder", cidr: "192.0.2.99/32",
                               holder_peer_ids: [], state: "unassigned")
    end

    before do
      mapping = Sdwan::PortMapping.new(account_id: account.id, sdwan_network_id: network.id,
                                       sdwan_peer_id: hub.id, target_virtual_ip_id: unassigned_vip.id,
                                       name: "skipped", listen_port: 9999, protocol: "tcp")
      mapping.save!(validate: false) # unassigned VIPs are uncommon; skip the model check
    end

    it "records the skip and produces zero rules" do
      out = described_class.compile_for_peer(hub)
      expect(out[:rule_count]).to eq(0)
      expect(out[:skipped].size).to eq(1)
      expect(out[:skipped].first[:reason]).to match(/unresolved/)
    end
  end
end
