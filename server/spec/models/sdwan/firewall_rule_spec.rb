# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::FirewallRule, type: :model do
  let(:account) { Account.first || create(:account) }
  let(:network) do
    Sdwan::Configuration.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
    Sdwan::Network.create!(account_id: account.id, name: "fw-rule-net-#{SecureRandom.hex(4)}")
  end

  describe "validations" do
    it "rejects unknown action / direction / protocol" do
      r = described_class.new(sdwan_network_id: network.id, name: "bad", action: "whoa")
      expect(r).not_to be_valid
      expect(r.errors[:action]).to be_present
    end

    it "rejects port range when protocol is not tcp/udp" do
      r = described_class.new(
        sdwan_network_id: network.id, name: "icmp-port", action: "accept",
        direction: "ingress", protocol: "icmp6", dst_port_range: (1..1024)
      )
      expect(r).not_to be_valid
      expect(r.errors[:dst_port_range]).to include("is only valid when protocol is tcp or udp")
    end

    it "accepts a port range with a tcp protocol" do
      r = described_class.new(
        sdwan_network_id: network.id, name: "ssh", action: "accept",
        direction: "ingress", protocol: "tcp", dst_port_range: (22..22)
      )
      expect(r).to be_valid
    end

    it "rejects multi-key selectors (must pick one kind)" do
      r = described_class.new(
        sdwan_network_id: network.id, name: "multikind", action: "accept",
        direction: "ingress", protocol: "any",
        src_selector: { "peer_id" => SecureRandom.uuid, "cidr" => "fd00::/64" }
      )
      expect(r).not_to be_valid
      expect(r.errors[:src_selector]).to include(/at most one selector kind/)
    end

    it "rejects unknown selector kinds" do
      r = described_class.new(
        sdwan_network_id: network.id, name: "weird", action: "accept",
        direction: "ingress", protocol: "any",
        src_selector: { "fictional" => "value" }
      )
      expect(r).not_to be_valid
      expect(r.errors[:src_selector]).to include(/at least one of/)
    end

    it "enforces uniqueness of name per network" do
      described_class.create!(
        sdwan_network_id: network.id, account_id: account.id,
        name: "duplicate", action: "accept", direction: "ingress", protocol: "any"
      )
      dup = described_class.new(
        sdwan_network_id: network.id, account_id: account.id,
        name: "duplicate", action: "drop", direction: "ingress", protocol: "any"
      )
      expect(dup).not_to be_valid
    end
  end

  describe "#port_range_hash" do
    let(:rule) do
      described_class.create!(
        sdwan_network_id: network.id, account_id: account.id,
        name: "ports", action: "accept", direction: "ingress", protocol: "tcp",
        dst_port_range: (1024..2048)
      )
    end

    it "exposes the JSON-friendly { from:, to: } shape" do
      # int4range can normalize to exclusive-upper "[1024,2049)"; the hash
      # accessor compensates so consumers always see inclusive bounds.
      h = rule.reload.port_range_hash
      expect(h[:from]).to eq(1024)
      expect(h[:to]).to eq(2048)
    end

    it "round-trips through the assignment accessor" do
      rule.port_range_hash = { from: 80, to: 80 }
      rule.save!
      expect(rule.reload.port_range_hash[:from]).to eq(80)
      expect(rule.reload.port_range_hash[:to]).to eq(80)
    end

    it "clears the column when assigned nil" do
      rule.port_range_hash = nil
      rule.save!
      expect(rule.reload.dst_port_range).to be_nil
    end
  end

  describe "auto-account inheritance" do
    it "copies account_id from the network on create" do
      rule = described_class.new(
        sdwan_network_id: network.id,
        name: "auto-acct", action: "accept", direction: "ingress", protocol: "any"
      )
      expect(rule).to be_valid
      rule.save!
      expect(rule.account_id).to eq(network.account_id)
    end
  end
end
