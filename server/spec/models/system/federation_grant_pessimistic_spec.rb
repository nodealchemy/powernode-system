# frozen_string_literal: true

require "rails_helper"

# Pessimistic-scope allowlists on FederationGrant (LD #12): node_instance_ids,
# sdwan_network_ids, source_cidrs.
#
# IMP-01166cdc69a7 (operator direction, no-legacy rule): a BLANK allowlist is a
# DENY on that axis, never "unrestricted". A grant that means "any" on an axis
# says so explicitly with the ANY sentinel ("*"), which must stand alone.
RSpec.describe System::FederationGrant, type: :model do
  let(:any) { described_class::ANY }

  describe "ANY sentinel" do
    it "is the literal *" do
      expect(described_class::ANY).to eq("*")
    end
  end

  describe "#unrestricted?" do
    it "is true only when every axis is explicitly ANY" do
      grant = build(:system_federation_grant, node_instance_ids: [ any ], sdwan_network_ids: [ any ], source_cidrs: [ any ])
      expect(grant.unrestricted?).to be true
    end

    it "is false when all three allowlists are blank (blank is deny, not unrestricted)" do
      grant = build(:system_federation_grant, node_instance_ids: [], sdwan_network_ids: [], source_cidrs: [])
      expect(grant.unrestricted?).to be false
    end

    it "is false when any axis is a concrete allowlist" do
      base = { node_instance_ids: [ any ], sdwan_network_ids: [ any ], source_cidrs: [ any ] }
      expect(build(:system_federation_grant, **base, node_instance_ids: [ "id1" ]).unrestricted?).to be false
      expect(build(:system_federation_grant, **base, sdwan_network_ids: [ "id1" ]).unrestricted?).to be false
      expect(build(:system_federation_grant, **base, source_cidrs: [ "10.0.0.0/8" ]).unrestricted?).to be false
    end
  end

  describe "#applies_to_instance?" do
    it "denies when the allowlist is blank, whatever is supplied" do
      grant = build(:system_federation_grant, node_instance_ids: [])
      expect(grant.applies_to_instance?("any-uuid")).to be false
      expect(grant.applies_to_instance?(nil)).to be false
    end

    it "allows anything, including an absent header, when the allowlist is ANY" do
      grant = build(:system_federation_grant, node_instance_ids: [ any ])
      expect(grant.applies_to_instance?("any-uuid")).to be true
      expect(grant.applies_to_instance?(nil)).to be true
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
    it "denies when the allowlist is blank" do
      grant = build(:system_federation_grant, sdwan_network_ids: [])
      expect(grant.applies_to_network?("any-uuid")).to be false
    end

    it "allows any network when the allowlist is ANY" do
      grant = build(:system_federation_grant, sdwan_network_ids: [ any ])
      expect(grant.applies_to_network?("any-uuid")).to be true
      expect(grant.applies_to_network?(nil)).to be true
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
    it "denies when the allowlist is blank" do
      grant = build(:system_federation_grant, source_cidrs: [])
      expect(grant.applies_to_source_ip?("10.0.0.1")).to be false
    end

    it "allows any source when the allowlist is ANY" do
      grant = build(:system_federation_grant, source_cidrs: [ any ])
      expect(grant.applies_to_source_ip?("10.0.0.1")).to be true
      expect(grant.applies_to_source_ip?(nil)).to be true
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

    it "passes regardless of supplied values only when every axis is explicitly ANY" do
      grant = build(:system_federation_grant, node_instance_ids: [ any ], sdwan_network_ids: [ any ], source_cidrs: [ any ])
      expect(grant.applies_to?(instance_id: nil, sdwan_network_id: nil, source_ip: nil)).to be true
    end

    it "fails for a grant whose allowlists are all blank (a row written around validation)" do
      grant = build(:system_federation_grant, node_instance_ids: [], sdwan_network_ids: [], source_cidrs: [])
      expect(grant.applies_to?(instance_id: "inst-a", sdwan_network_id: "net-x", source_ip: "10.1.2.3")).to be false
    end
  end

  describe "validation" do
    it "refuses a grant with a blank allowlist on any axis" do
      %i[node_instance_ids sdwan_network_ids source_cidrs].each do |axis|
        grant = build(:system_federation_grant, axis => [])
        expect(grant).not_to be_valid, "#{axis} blank must be invalid"
        expect(grant.errors[axis].join).to match(/ANY|\*/)
      end
    end

    it "refuses ANY mixed with concrete entries" do
      expect(build(:system_federation_grant, node_instance_ids: [ any, "abc" ])).not_to be_valid
      expect(build(:system_federation_grant, sdwan_network_ids: [ "net-a", any ])).not_to be_valid
      expect(build(:system_federation_grant, source_cidrs: [ any, "10.0.0.0/8" ])).not_to be_valid
    end

    it "still lets a row written around validation be revoked and archived (it denies meanwhile)" do
      grant = create(:system_federation_grant)
      grant.update_columns(node_instance_ids: [], sdwan_network_ids: [ any, "abc" ], source_cidrs: [])

      expect(grant.reload.applies_to?(instance_id: "x", sdwan_network_id: "abc", source_ip: "10.0.0.1")).to be false
      expect { grant.revoke!(reason: "cleanup") }.not_to raise_error
      expect { grant.archive! }.not_to raise_error
      expect(grant.reload).to be_revoked.and be_archived
    end

    it "re-checks the axes when one of them is changed on an existing grant" do
      grant = create(:system_federation_grant)
      expect(grant.update(source_cidrs: [])).to be false
      expect(grant.errors[:source_cidrs].join).to match(/ANY|\*/)
    end

    it "denies a non-array axis rather than coercing it (a row written around validation)" do
      grant = build(:system_federation_grant, node_instance_ids: any, sdwan_network_ids: any, source_cidrs: any)
      expect(grant.applies_to_instance?(any)).to be false
      expect(grant.applies_to_network?(any)).to be false
      expect(grant.unrestricted?).to be false
    end

    it "accepts ANY alone and concrete allowlists on every axis" do
      expect(build(:system_federation_grant, node_instance_ids: [ any ], sdwan_network_ids: [ any ], source_cidrs: [ any ])).to be_valid
      expect(build(:system_federation_grant, node_instance_ids: %w[abc], sdwan_network_ids: %w[net-a], source_cidrs: %w[10.0.0.0/8])).to be_valid
    end
  end
end
