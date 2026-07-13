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
      expect(result[:chain]).to eq("sdwan_#{network.id.to_s.delete('-').first(6)}")
      expect(result[:interface]).to eq("wg-sdwan-#{network.id.to_s.delete('-').first(6)}")
      expect(result[:policy]).to eq("accept")
      expect(result[:rule_count]).to eq(0)
      expect(result[:ruleset]).to include("add table inet powernode_sdwan")
      expect(result[:ruleset]).to include("policy accept")
      expect(result[:ruleset]).to include("flush chain inet powernode_sdwan #{result[:chain]}")
    end

    it "SAFETY: never installs an unscoped base-chain drop policy — it would brick all non-SDWAN host input (SSH, heartbeats, DNS)" do
      network.update!(settings: { "firewall_default_policy" => "drop" })
      compiler = described_class.new(network)
      out = compiler.compile[:ruleset]

      # The base-chain `policy` directive fires for EVERY packet at the
      # input hook — not just packets on this network's SDWAN interface —
      # so it must always stay "accept". Allowlist mode is instead
      # enforced with an explicit iif-scoped drop rule appended after all
      # configured rules, so only this network's peer interface is denied
      # by default; every other interface (management SSH, agent
      # heartbeats, DNS, ...) falls through to the chain's accept policy
      # untouched.
      expect(out).not_to include("policy drop")
      expect(out).to include("policy accept")
      expect(out).to include(%(add rule inet powernode_sdwan #{compiler.chain_name} iif "#{compiler.interface_name}" drop))
    end

    it "respects firewall_default_policy=drop via a scoped deny-all rule, not the base-chain policy" do
      network.update!(settings: { "firewall_default_policy" => "drop" })
      expect(described_class.new(network).default_policy).to eq("drop")
      expect(described_class.new(network).compile[:policy]).to eq("drop")
    end

    it "orders the scoped deny-all rule after explicit allow rules so allowlisted traffic still matches first" do
      Sdwan::FirewallRule.create!(
        sdwan_network_id: network.id, account_id: account.id,
        name: "allow-ssh", priority: 100,
        action: "accept", direction: "ingress", protocol: "tcp",
        dst_port_range: (22..22)
      )
      network.update!(settings: { "firewall_default_policy" => "drop" })
      compiler = described_class.new(network)
      lines = compiler.compile[:ruleset].lines.map(&:chomp)

      allow_index = lines.index { |l| l.include?("tcp dport 22 accept") }
      deny_index  = lines.index { |l| l.end_with?(%(iif "#{compiler.interface_name}" drop)) }

      expect(allow_index).not_to be_nil
      expect(deny_index).not_to be_nil
      expect(allow_index).to be < deny_index
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

    it "DROPS a restrict-by-tag rule whose tag matches no peers (fail closed, not wildcard)" do
      Sdwan::FirewallRule.create!(
        sdwan_network_id: network.id, account_id: account.id,
        name: "restrict-to-db-tag", priority: 100,
        action: "accept", direction: "ingress", protocol: "tcp",
        dst_port_range: (5432..5432),
        src_selector: { "tag" => "database" }
      )
      out = described_class.new(network).compile[:ruleset]
      # Emitting this rule WITHOUT the (empty) saddr clause would accept 5432
      # from every peer — the old fail-open bug. It must be dropped entirely.
      expect(out).not_to include("tcp dport 5432")
    end

    it "DROPS a rule whose peer_id selector points at a deleted peer (fail closed)" do
      Sdwan::FirewallRule.create!(
        sdwan_network_id: network.id, account_id: account.id,
        name: "restrict-to-ghost", priority: 100,
        action: "accept", direction: "ingress", protocol: "tcp",
        dst_port_range: (2222..2222),
        src_selector: { "peer_id" => SecureRandom.uuid }
      )
      out = described_class.new(network).compile[:ruleset]
      expect(out).not_to include("tcp dport 2222")
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
