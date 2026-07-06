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
                               holder_peer_ids: [ target.id ], state: "active")
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

  # ─── Campaign 019f3458 increment 6: hardened DNAT tier ─────────────────

  describe "regression: hardening columns unset compiles byte-identical to today's output" do
    before do
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "plain", listen_port: 4444, protocol: "tcp")
    end

    it "emits exactly the bare dnat line — no saddr/drop/limit/ct constructs" do
      out = described_class.compile_for_peer(hub)
      addr = target.assigned_address.split("/").first
      expect(out[:rule_count]).to eq(1)
      expect(out[:ruleset]).to include("    tcp dport 4444 dnat to [#{addr}]:4444\n")
      expect(out[:ruleset]).not_to include("drop")
      expect(out[:ruleset]).not_to include("saddr")
      expect(out[:ruleset]).not_to include("limit rate")
      expect(out[:ruleset]).not_to include("ct count")
      expect(out[:ruleset]).not_to include("nfproto")
    end
  end

  describe "source_cidrs enforcement" do
    it "emits an ip saddr allow-list negation + a full ipv6 block when only v4 CIDRs are set" do
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "v4-restricted", listen_port: 5000, protocol: "tcp",
                                 source_cidrs: [ "203.0.113.0/24" ])
      out = described_class.compile_for_peer(hub)
      expect(out[:ruleset]).to include('tcp dport 5000 ip saddr != { 203.0.113.0/24 } drop')
      expect(out[:ruleset]).to include("tcp dport 5000 meta nfproto ipv6 drop")
    end

    it "emits an ip6 saddr allow-list negation + a full ipv4 block when only v6 CIDRs are set" do
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "v6-restricted", listen_port: 5001, protocol: "tcp",
                                 source_cidrs: [ "2001:db8::/32" ])
      out = described_class.compile_for_peer(hub)
      expect(out[:ruleset]).to include("tcp dport 5001 meta nfproto ipv4 drop")
      expect(out[:ruleset]).to include('tcp dport 5001 ip6 saddr != { 2001:db8::/32 } drop')
    end

    it "emits both family negations when v4 and v6 CIDRs are mixed" do
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "mixed-restricted", listen_port: 5002, protocol: "tcp",
                                 source_cidrs: [ "203.0.113.0/24", "2001:db8::/32" ])
      out = described_class.compile_for_peer(hub)
      expect(out[:ruleset]).to include('tcp dport 5002 ip saddr != { 203.0.113.0/24 } drop')
      expect(out[:ruleset]).to include('tcp dport 5002 ip6 saddr != { 2001:db8::/32 } drop')
      expect(out[:ruleset]).not_to include("nfproto")
    end

    it "joins multiple CIDRs in the same family into one set" do
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "multi-v4", listen_port: 5003, protocol: "tcp",
                                 source_cidrs: [ "203.0.113.0/24", "198.51.100.0/24" ])
      out = described_class.compile_for_peer(hub)
      expect(out[:ruleset]).to include('ip saddr != { 203.0.113.0/24, 198.51.100.0/24 } drop')
    end

    it "still emits the underlying dnat rule after the guard lines" do
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "still-dnats", listen_port: 5004, protocol: "tcp",
                                 source_cidrs: [ "203.0.113.0/24" ])
      out = described_class.compile_for_peer(hub)
      addr = target.assigned_address.split("/").first
      expect(out[:ruleset]).to include("dnat to [#{addr}]:5004")
      guard_idx = out[:ruleset].index("ip saddr !=")
      dnat_idx  = out[:ruleset].index("dnat to")
      expect(guard_idx).to be < dnat_idx
    end
  end

  describe "max_connections enforcement" do
    it "emits a ct count over <n> drop guard before the dnat rule" do
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "conn-capped", listen_port: 5100, protocol: "tcp",
                                 max_connections: 50)
      out = described_class.compile_for_peer(hub)
      expect(out[:ruleset]).to include("tcp dport 5100 ct count over 50 drop")
      guard_idx = out[:ruleset].index("ct count over 50 drop")
      dnat_idx  = out[:ruleset].index("dnat to")
      expect(guard_idx).to be < dnat_idx
    end
  end

  describe "rate_limit enforcement" do
    it "emits a limit rate over <n>/second drop guard before the dnat rule" do
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "rate-capped", listen_port: 5200, protocol: "udp",
                                 rate_limit: 100)
      out = described_class.compile_for_peer(hub)
      expect(out[:ruleset]).to include("udp dport 5200 limit rate over 100/second drop")
      guard_idx = out[:ruleset].index("limit rate over 100/second drop")
      dnat_idx  = out[:ruleset].index("dnat to")
      expect(guard_idx).to be < dnat_idx
    end
  end

  describe "combined hardening" do
    it "orders guards as source-cidrs, then max_connections, then rate_limit, then dnat" do
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "fully-hardened", listen_port: 5300, protocol: "tcp",
                                 source_cidrs: [ "203.0.113.0/24" ], max_connections: 10, rate_limit: 5)
      out = described_class.compile_for_peer(hub)
      rs = out[:ruleset]
      saddr_idx = rs.index("ip saddr !=")
      nfproto_idx = rs.index("nfproto ipv6 drop")
      ct_idx = rs.index("ct count over 10 drop")
      limit_idx = rs.index("limit rate over 5/second drop")
      dnat_idx = rs.index("dnat to")

      expect(saddr_idx).to be < nfproto_idx
      expect(nfproto_idx).to be < ct_idx
      expect(ct_idx).to be < limit_idx
      expect(limit_idx).to be < dnat_idx
    end

    it "does not cross-contaminate an adjacent unhardened mapping on the same hub" do
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "hardened", listen_port: 5400, protocol: "tcp",
                                 rate_limit: 5)
      Sdwan::PortMapping.create!(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "plain-sibling", listen_port: 5401, protocol: "tcp")
      out = described_class.compile_for_peer(hub)
      expect(out[:rule_count]).to eq(3) # 1 guard line + 2 dnat lines
      expect(out[:ruleset]).to include("tcp dport 5400 limit rate over 5/second drop")
      expect(out[:ruleset]).not_to include("dport 5401 limit rate")
      expect(out[:ruleset]).not_to include("dport 5401 ct count")
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
