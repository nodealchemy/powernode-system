# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::IpAllowlistService do
  describe ".security_group_rules_for" do
    let(:account) { build_stubbed(:account, metadata: account_metadata) }
    let(:account_metadata) { {} }

    context "when no allowlist is configured anywhere" do
      it "returns an empty array (caller falls back to defaults)" do
        expect(described_class.security_group_rules_for(account: account)).to eq([])
      end

      it "treats nil metadata as empty" do
        account_no_meta = build_stubbed(:account)
        allow(account_no_meta).to receive(:metadata).and_return(nil)
        expect(described_class.security_group_rules_for(account: account_no_meta)).to eq([])
      end
    end

    context "when only the account has an allowlist" do
      let(:account_metadata) { { "ip_allowlist" => [ "1.2.3.0/24" ] } }

      it "emits SSH/HTTP/HTTPS rules for each CIDR" do
        rules = described_class.security_group_rules_for(account: account)

        expect(rules.size).to eq(3)
        expect(rules.map { |r| r[:port] }).to match_array([ 22, 80, 443 ])
        expect(rules.map { |r| r[:source] }.uniq).to eq([ "1.2.3.0/24" ])
        expect(rules).to all(include(:protocol, :port, :source, :description))
      end

      it "labels each rule with the originating CIDR" do
        rules = described_class.security_group_rules_for(account: account)
        ssh = rules.find { |r| r[:port] == 22 }
        expect(ssh[:description]).to eq("SSH from 1.2.3.0/24")
      end
    end

    context "with multiple CIDRs" do
      let(:account_metadata) do
        { "ip_allowlist" => [ "1.2.3.0/24", "10.0.0.0/8", "192.168.1.1/32" ] }
      end

      it "emits one rule per (CIDR × port) pair" do
        rules = described_class.security_group_rules_for(account: account)

        expect(rules.size).to eq(9) # 3 CIDRs × 3 ports
        expect(rules.map { |r| r[:source] }.uniq).to match_array(
          %w[1.2.3.0/24 10.0.0.0/8 192.168.1.1/32]
        )
      end

      it "deduplicates exact-match CIDRs across sources" do
        delegation = double("Delegation", ip_allowlist: [ "1.2.3.0/24" ])

        rules = described_class.security_group_rules_for(
          account: account,
          delegation: delegation
        )

        # 3 unique CIDRs (1.2.3.0/24 dedup'd) × 3 ports = 9
        expect(rules.size).to eq(9)
        expect(rules.map { |r| r[:source] }.uniq).to match_array(
          %w[1.2.3.0/24 10.0.0.0/8 192.168.1.1/32]
        )
      end
    end

    context "when a delegation supplies additional CIDRs" do
      let(:account_metadata) { { "ip_allowlist" => [ "10.0.0.0/8" ] } }
      let(:delegation) { double("Delegation", ip_allowlist: [ "172.16.0.0/12" ]) }

      it "merges delegation entries with account entries (additive)" do
        rules = described_class.security_group_rules_for(
          account: account,
          delegation: delegation
        )

        sources = rules.map { |r| r[:source] }.uniq
        expect(sources).to match_array(%w[10.0.0.0/8 172.16.0.0/12])
      end
    end

    context "when a delegation lacks the ip_allowlist column" do
      let(:account_metadata) { { "ip_allowlist" => [ "10.0.0.0/8" ] } }

      # Slice A may not have shipped yet — legacy delegations that
      # don't respond to :ip_allowlist must not raise NoMethodError.
      it "ignores the delegation gracefully" do
        legacy_delegation = Object.new # respond_to?(:ip_allowlist) is false

        rules = described_class.security_group_rules_for(
          account: account,
          delegation: legacy_delegation
        )

        expect(rules.map { |r| r[:source] }.uniq).to eq([ "10.0.0.0/8" ])
      end
    end

    context "with mixed entry shapes" do
      let(:account_metadata) do
        {
          "ip_allowlist" => [
            "1.2.3.0/24",
            { "cidr" => "5.6.7.0/24", "label" => "office" },
            { cidr: "9.10.11.0/24" },
            [ "12.13.14.0/24", "ignored extra" ],
            "  ", # blank — must be dropped
            nil   # nil — must be dropped
          ]
        }
      end

      it "normalizes hash and array forms to plain CIDR strings" do
        rules = described_class.security_group_rules_for(account: account)
        sources = rules.map { |r| r[:source] }.uniq.sort
        expect(sources).to eq(%w[1.2.3.0/24 12.13.14.0/24 5.6.7.0/24 9.10.11.0/24])
      end
    end

    context "when only a delegation has an allowlist (account empty)" do
      let(:delegation) { double("Delegation", ip_allowlist: [ "8.8.8.0/24" ]) }

      it "uses the delegation entries" do
        rules = described_class.security_group_rules_for(
          account: account,
          delegation: delegation
        )

        expect(rules.map { |r| r[:source] }.uniq).to eq([ "8.8.8.0/24" ])
        expect(rules.size).to eq(3)
      end
    end
  end
end
