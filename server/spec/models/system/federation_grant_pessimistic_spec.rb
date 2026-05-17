# frozen_string_literal: true

require "rails_helper"

# Covers the P4.5 pessimistic-scope additions to FederationGrant
# (LD #12). The pre-LD#12 grant behavior is covered in
# `federation_grant_spec.rb`; this file focuses on the new
# instance/network/CIDR allowlist semantics.
RSpec.describe System::FederationGrant, type: :model do
  describe "#unrestricted?" do
    it "is true when all three allowlists are empty" do
      grant = build(:system_federation_grant)
      expect(grant.unrestricted?).to be true
    end

    it "is false when any allowlist is populated" do
      expect(build(:system_federation_grant, node_instance_ids: [ "id1" ]).unrestricted?).to be false
      expect(build(:system_federation_grant, sdwan_network_ids: [ "id1" ]).unrestricted?).to be false
      expect(build(:system_federation_grant, source_cidrs: [ "10.0.0.0/8" ]).unrestricted?).to be false
    end
  end

  describe "#applies_to_instance?" do
    it "is true when allowlist empty (back-compat — no restriction)" do
      grant = build(:system_federation_grant, node_instance_ids: [])
      expect(grant.applies_to_instance?("any-uuid")).to be true
    end

    it "is true when supplied instance is in the allowlist" do
      grant = build(:system_federation_grant, node_instance_ids: %w[abc def])
      expect(grant.applies_to_instance?("abc")).to be true
    end

    it "is false when supplied instance is NOT in the allowlist" do
      grant = build(:system_federation_grant, node_instance_ids: %w[abc def])
      expect(grant.applies_to_instance?("ghi")).to be false
    end

    it "is false when allowlist is populated but the supplied value is blank" do
      grant = build(:system_federation_grant, node_instance_ids: %w[abc])
      expect(grant.applies_to_instance?(nil)).to be false
      expect(grant.applies_to_instance?("")).to be false
    end
  end

  describe "#applies_to_network?" do
    it "is true when allowlist empty (back-compat)" do
      grant = build(:system_federation_grant, sdwan_network_ids: [])
      expect(grant.applies_to_network?("any-uuid")).to be true
    end

    it "matches when supplied network is in allowlist" do
      grant = build(:system_federation_grant, sdwan_network_ids: %w[net-a net-b])
      expect(grant.applies_to_network?("net-a")).to be true
    end

    it "rejects when supplied network is NOT in allowlist" do
      grant = build(:system_federation_grant, sdwan_network_ids: %w[net-a])
      expect(grant.applies_to_network?("net-c")).to be false
    end
  end

  describe "#applies_to_source_ip?" do
    it "is true when allowlist empty" do
      grant = build(:system_federation_grant, source_cidrs: [])
      expect(grant.applies_to_source_ip?("10.0.0.1")).to be true
    end

    it "matches an IPv4 in a /24 CIDR" do
      grant = build(:system_federation_grant, source_cidrs: %w[10.0.0.0/24])
      expect(grant.applies_to_source_ip?("10.0.0.42")).to be true
      expect(grant.applies_to_source_ip?("10.0.1.42")).to be false
    end

    it "matches an IPv6 in a /64 CIDR" do
      grant = build(:system_federation_grant, source_cidrs: %w[fd00:abcd::/64])
      expect(grant.applies_to_source_ip?("fd00:abcd::1")).to be true
      expect(grant.applies_to_source_ip?("fd00:dead::1")).to be false
    end

    it "rejects when supplied IP is blank but allowlist populated" do
      grant = build(:system_federation_grant, source_cidrs: %w[10.0.0.0/8])
      expect(grant.applies_to_source_ip?(nil)).to be false
    end

    it "rejects (without crashing) on malformed CIDRs" do
      grant = build(:system_federation_grant, source_cidrs: [ "not-an-address" ])
      expect(grant.applies_to_source_ip?("10.0.0.1")).to be false
    end

    it "rejects (without crashing) on malformed source IP" do
      grant = build(:system_federation_grant, source_cidrs: %w[10.0.0.0/8])
      expect(grant.applies_to_source_ip?("not-an-ip")).to be false
    end

    it "matches across multiple CIDRs in the allowlist" do
      grant = build(:system_federation_grant, source_cidrs: %w[10.0.0.0/8 192.168.1.0/24])
      expect(grant.applies_to_source_ip?("10.5.5.5")).to be true
      expect(grant.applies_to_source_ip?("192.168.1.50")).to be true
      expect(grant.applies_to_source_ip?("172.16.0.1")).to be false
    end
  end

  describe "#applies_to? (combined)" do
    it "passes when ALL three axes match" do
      grant = build(:system_federation_grant,
                    node_instance_ids: %w[inst-a],
                    sdwan_network_ids: %w[net-x],
                    source_cidrs: %w[10.0.0.0/8])
      expect(grant.applies_to?(instance_id: "inst-a",
                                sdwan_network_id: "net-x",
                                source_ip: "10.1.2.3")).to be true
    end

    it "fails when any single axis fails" do
      grant = build(:system_federation_grant,
                    node_instance_ids: %w[inst-a],
                    sdwan_network_ids: %w[net-x],
                    source_cidrs: %w[10.0.0.0/8])
      expect(grant.applies_to?(instance_id: "other-inst",
                                sdwan_network_id: "net-x",
                                source_ip: "10.1.2.3")).to be false
      expect(grant.applies_to?(instance_id: "inst-a",
                                sdwan_network_id: "other-net",
                                source_ip: "10.1.2.3")).to be false
      expect(grant.applies_to?(instance_id: "inst-a",
                                sdwan_network_id: "net-x",
                                source_ip: "8.8.8.8")).to be false
    end

    it "passes regardless of supplied values when grant is unrestricted (back-compat)" do
      grant = build(:system_federation_grant)
      expect(grant.unrestricted?).to be true
      expect(grant.applies_to?(instance_id: nil, sdwan_network_id: nil, source_ip: nil)).to be true
    end
  end
end
