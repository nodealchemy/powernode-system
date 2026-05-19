# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::Network, type: :model do
  let(:account) { Account.first || create(:account) }

  describe "#allocate_address_space (before_validation on create)" do
    it "auto-allocates a /64 CIDR if none provided" do
      Sdwan::Configuration.where(account_id: account.id).delete_all
      Sdwan::Network.where(account_id: account.id).delete_all
      net = described_class.create!(account_id: account.id, name: "auto-cidr")
      expect(net.cidr_64).to match(%r{\Afd[0-9a-f:]+::/64\z})
    end

    it "respects an explicit cidr_64 if provided" do
      Sdwan::Configuration.where(account_id: account.id).delete_all
      Sdwan::Network.where(account_id: account.id).delete_all
      net = described_class.create!(
        account_id: account.id, name: "explicit-cidr",
        cidr_64: "fd00:1234:5678:9abc::/64"
      )
      expect(net.cidr_64).to eq("fd00:1234:5678:9abc::/64")
    end
  end

  describe "validations" do
    it "rejects names that clash within an account" do
      Sdwan::Configuration.where(account_id: account.id).delete_all
      Sdwan::Network.where(account_id: account.id).delete_all
      described_class.create!(account_id: account.id, name: "duplicate-net")
      dup = described_class.new(account_id: account.id, name: "duplicate-net")
      expect(dup).not_to be_valid
      expect(dup.errors[:name]).to include("has already been taken")
    end

    it "rejects unknown statuses" do
      net = described_class.new(account_id: account.id, name: "bad-status", status: "explosive")
      expect(net).not_to be_valid
      expect(net.errors[:status]).to be_present
    end
  end

  describe "#generate_slug" do
    it "derives a URL-safe slug from the name" do
      Sdwan::Network.where(account_id: account.id).delete_all
      net = described_class.create!(account_id: account.id, name: "  My Edge Net  !!  ")
      expect(net.slug).to eq("my-edge-net")
    end
  end

  describe "scopes" do
    before do
      Sdwan::Network.where(account_id: account.id).delete_all
      described_class.create!(account_id: account.id, name: "active-net",     status: "active")
      described_class.create!(account_id: account.id, name: "registered-net", status: "registered")
      described_class.create!(account_id: account.id, name: "archived-net",   status: "archived")
    end

    it "compilable scope includes registered + active, not archived/suspended" do
      compilable = described_class.compilable.where(account_id: account.id).pluck(:name)
      expect(compilable).to contain_exactly("active-net", "registered-net")
    end
  end

  # K3s overlay (2026-05-19) — pod_subnet_prefix validation + overlap + immutability.
  describe "#pod_subnet_prefix validation" do
    before do
      Sdwan::Configuration.where(account_id: account.id).delete_all
      Sdwan::Network.where(account_id: account.id).delete_all
    end

    let(:network) do
      described_class.create!(
        account_id: account.id,
        name: "pod-net-#{SecureRandom.hex(4)}",
        cidr_64: "fd00:abcd:1::/64"
      )
    end

    it "accepts an IPv4 pod CIDR (the flannel default shape)" do
      network.update(pod_subnet_prefix: "10.42.0.0/16")
      expect(network).to be_valid
      expect(network.pod_overlay_enabled?).to be true
    end

    it "accepts a null pod_subnet_prefix (overlay disabled, default)" do
      network.update(pod_subnet_prefix: nil)
      expect(network).to be_valid
      expect(network.pod_overlay_enabled?).to be false
    end

    it "rejects malformed CIDRs" do
      network.pod_subnet_prefix = "not-a-cidr"
      expect(network).not_to be_valid
      expect(network.errors[:pod_subnet_prefix].join).to match(/CIDR/)
    end

    it "rejects IPv4 CIDRs smaller than /28 (pods need address space)" do
      network.pod_subnet_prefix = "10.42.0.0/30"
      expect(network).not_to be_valid
      expect(network.errors[:pod_subnet_prefix].join).to match(%r{/28 or larger})
    end

    it "rejects pod CIDRs that overlap the SDWAN /64" do
      # The SDWAN /64 is IPv6 fd00:abcd:1::/64; using an IPv6 pod CIDR that
      # falls within it should be rejected.
      network.pod_subnet_prefix = "fd00:abcd:1::/96"
      expect(network).not_to be_valid
      expect(network.errors[:pod_subnet_prefix].join).to match(/SDWAN/)
    end

    it "rejects pod CIDRs that overlap another network's pod_subnet_prefix in the same account" do
      other = described_class.create!(
        account_id: account.id,
        name: "other-pod-net-#{SecureRandom.hex(4)}",
        cidr_64: "fd00:abcd:2::/64",
        pod_subnet_prefix: "10.42.0.0/16"
      )
      _ = other
      network.pod_subnet_prefix = "10.42.5.0/24" # overlaps 10.42.0.0/16
      expect(network).not_to be_valid
      expect(network.errors[:pod_subnet_prefix].join).to match(/overlap/)
    end

    it "allows non-overlapping pod_subnet_prefix in different networks" do
      described_class.create!(
        account_id: account.id,
        name: "first-pod-net-#{SecureRandom.hex(4)}",
        cidr_64: "fd00:abcd:2::/64",
        pod_subnet_prefix: "10.42.0.0/16"
      )
      network.pod_subnet_prefix = "10.43.0.0/16"
      expect(network).to be_valid
    end
  end
end
