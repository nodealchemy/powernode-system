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
end
