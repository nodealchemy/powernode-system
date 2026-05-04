# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::FirewallCompiler, type: :service do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::Configuration.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
  end

  let!(:network) { Sdwan::Network.create!(account_id: account.id, name: "fw-net-#{SecureRandom.hex(4)}") }

  describe "#compile with no rules" do
    it "emits the table + chain scaffolding with the default accept policy" do
      result = described_class.new(network).compile
      expect(result[:table]).to eq("powernode_sdwan")
      expect(result[:chain]).to eq("sdwan_#{network.id.to_s.delete('-').first(8)}")
      expect(result[:interface]).to eq("wg-sdwan-#{network.id.to_s.delete('-').first(8)}")
      expect(result[:policy]).to eq("accept")
      expect(result[:rule_count]).to eq(0)
      expect(result[:ruleset]).to include("add table inet powernode_sdwan")
      expect(result[:ruleset]).to include("policy accept")
      expect(result[:ruleset]).to include("flush chain inet powernode_sdwan #{result[:chain]}")
    end

    it "respects firewall_default_policy=drop in network settings" do
      network.update!(settings: { "firewall_default_policy" => "drop" })
      expect(described_class.new(network).default_policy).to eq("drop")
      expect(described_class.new(network).compile[:ruleset]).to include("policy drop")
    end

    it "falls back to accept when firewall_default_policy is unrecognized" do
      network.update!(settings: { "firewall_default_policy" => "burninate" })
      expect(described_class.new(network).default_policy).to eq("accept")
    end
  end

  describe "rule emission" do
    it "compiles a wildcard accept rule" do
      Sdwan::FirewallRule.create!(
        sdwan_network_id: network.id, account_id: account.id,
        name: "allow-all-icmp6", priority: 100,
        action: "accept", direction: "ingress", protocol: "icmp6"
      )
      out = described_class.new(network).compile[:ruleset]
      expect(out).to match(/add rule inet powernode_sdwan sdwan_\w+ iif "wg-sdwan-\w+" ip6 nexthdr icmpv6 accept/)
    end

    it "compiles a tcp/port rule" do
      Sdwan::FirewallRule.create!(
        sdwan_network_id: network.id, account_id: account.id,
        name: "allow-ssh", priority: 100,
        action: "accept", direction: "ingress", protocol: "tcp",
        dst_port_range: (22..22)
      )
      out = described_class.new(network).compile[:ruleset]
      expect(out).to include("tcp dport 22 accept")
    end

    it "compiles a port range" do
      Sdwan::FirewallRule.create!(
        sdwan_network_id: network.id, account_id: account.id,
        name: "high-ports", priority: 100,
        action: "accept", direction: "ingress", protocol: "udp",
        dst_port_range: (3000..4000)
      )
      out = described_class.new(network).compile[:ruleset]
      expect(out).to include("udp dport { 3000-4000 } accept")
    end

    it "skips egress-only rules in slice 2 (input-hook only)" do
      Sdwan::FirewallRule.create!(
        sdwan_network_id: network.id, account_id: account.id,
        name: "egress-only", priority: 100, action: "accept",
        direction: "egress", protocol: "any"
      )
      result = described_class.new(network).compile
      expect(result[:rule_count]).to eq(1)            # row count is unfiltered
      expect(result[:ruleset]).not_to include("egress-only")  # but it's not emitted
    end

    it "skips disabled rules" do
      Sdwan::FirewallRule.create!(
        sdwan_network_id: network.id, account_id: account.id,
        name: "off-rule", priority: 100, action: "accept",
        direction: "ingress", protocol: "any", enabled: false
      )
      result = described_class.new(network).compile
      expect(result[:rule_count]).to eq(0)
      expect(result[:ruleset]).not_to include("off-rule")
    end

    it "compiles cidr selectors into ip6 saddr / daddr clauses" do
      Sdwan::FirewallRule.create!(
        sdwan_network_id: network.id, account_id: account.id,
        name: "from-net", priority: 100, action: "accept",
        direction: "ingress", protocol: "tcp",
        src_selector: { "cidr" => "fd00:1::/64" },
        dst_port_range: (80..80)
      )
      out = described_class.new(network).compile[:ruleset]
      expect(out).to include("ip6 saddr fd00:1::/64")
      expect(out).to include("tcp dport 80 accept")
    end
  end
end
