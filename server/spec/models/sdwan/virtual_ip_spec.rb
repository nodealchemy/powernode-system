# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::VirtualIp, type: :model do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::VirtualIp.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
    Sdwan::Configuration.where(account_id: account.id).delete_all
  end

  let!(:network) { Sdwan::Network.create!(account_id: account.id, name: "vip-net-#{SecureRandom.hex(3)}") }
  let!(:node) { sdwan_test_node(account: account) }
  let!(:inst1) { sdwan_test_node_instance(node: node) }
  let!(:inst2) { sdwan_test_node_instance(node: node) }
  let!(:hub) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst1,
                        publicly_reachable: true, endpoint_host_v6: "2001:db8::1", endpoint_port: 51820)
  end
  let!(:spoke) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst2,
                        publicly_reachable: false)
  end

  describe "validations" do
    it "rejects anycast VIPs with fewer than two holders" do
      vip = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                                name: "bad-anycast", cidr: "192.0.2.10/32",
                                anycast: true, holder_peer_ids: [hub.id], state: "pending")
      expect(vip).not_to be_valid
      expect(vip.errors[:holder_peer_ids].join).to match(/at least 2 holders/)
    end

    it "accepts anycast VIPs with two or more holders" do
      vip = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                                name: "good-anycast", cidr: "192.0.2.20/32",
                                anycast: true, holder_peer_ids: [hub.id, spoke.id], state: "active")
      expect(vip).to be_valid
    end

    it "rejects holder peers from another network" do
      other_net = Sdwan::Network.create!(account_id: account.id, name: "other-net-#{SecureRandom.hex(3)}")
      foreign = Sdwan::Peer.create!(account: account, sdwan_network_id: other_net.id,
                                    node_instance: inst1, publicly_reachable: false)
      vip = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                                name: "cross-net", cidr: "192.0.2.30/32",
                                holder_peer_ids: [foreign.id], state: "pending")
      expect(vip).not_to be_valid
      expect(vip.errors[:holder_peer_ids].join).to match(/another network/)
    end

    it "enforces CIDR format" do
      vip = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                                name: "bad-cidr", cidr: "not-a-cidr", state: "pending")
      expect(vip).not_to be_valid
      expect(vip.errors[:cidr]).to be_present
    end
  end

  describe "#failover!" do
    let!(:vip) do
      described_class.create!(account_id: account.id, sdwan_network_id: network.id,
                              name: "fo-vip", cidr: "192.0.2.50/32",
                              holder_peer_ids: [hub.id],
                              failover_holder_peer_ids: [spoke.id], state: "active")
    end

    it "promotes the head of failover_holder_peer_ids and writes an assignment row" do
      expect { vip.failover! }
        .to change { Sdwan::VirtualIpAssignment.where(sdwan_virtual_ip_id: vip.id).count }.by(1)
      vip.reload
      expect(vip.holder_peer_ids).to start_with(spoke.id)
      expect(vip.failover_holder_peer_ids).to include(hub.id)
    end

    it "raises StateError on anycast VIPs (BGP handles their failover)" do
      vip.update!(anycast: true, holder_peer_ids: [hub.id, spoke.id])
      expect { vip.failover! }.to raise_error(Sdwan::VirtualIp::StateError, /anycast/)
    end

    it "raises StateError when failover_holder_peer_ids is empty" do
      vip.update!(failover_holder_peer_ids: [])
      expect { vip.failover! }.to raise_error(Sdwan::VirtualIp::StateError, /no failover candidates/)
    end
  end
end
