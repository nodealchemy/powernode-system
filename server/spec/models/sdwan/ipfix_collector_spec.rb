# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::IpfixCollector, type: :model do
  let(:account) { Account.first || create(:account) }

  before do
    described_class.where(account_id: account.id).delete_all
  end

  def build_collector(overrides = {})
    described_class.new({
      account: account,
      name: "test-#{SecureRandom.hex(3)}",
      host: "10.0.0.1",
      port: 4739,
      sampling_rate: 1
    }.merge(overrides))
  end

  describe "validations" do
    it "is valid with sane attributes" do
      expect(build_collector).to be_valid
    end

    it "requires host + name" do
      [{ host: "" }, { name: "" }].each do |over|
        c = build_collector(over)
        expect(c).not_to be_valid, "expected invalid for #{over.inspect}"
      end
    end

    it "rejects port outside 1..65535" do
      [0, 65_536, -1].each do |bad|
        c = build_collector(port: bad)
        expect(c).not_to be_valid
        expect(c.errors[:port]).to be_present
      end
    end

    it "rejects sampling_rate < 1" do
      c = build_collector(sampling_rate: 0)
      expect(c).not_to be_valid
      expect(c.errors[:sampling_rate]).to be_present
    end

    it "enforces (account, name) uniqueness" do
      build_collector(name: "dup").save!
      dup = build_collector(name: "dup")
      expect(dup).not_to be_valid
      expect(dup.errors[:name]).to be_present
    end
  end

  describe "AASM lifecycle" do
    let(:collector) { build_collector.tap(&:save!) }

    it "starts in :active" do
      expect(collector.state).to eq("active")
    end

    it "transitions active -> disabled and back" do
      collector.disable!
      expect(collector.reload.state).to eq("disabled")
      collector.enable!
      expect(collector.reload.state).to eq("active")
    end
  end

  describe "scopes" do
    let!(:active_one)   { build_collector(name: "a").tap(&:save!) }
    let!(:disabled_one) { build_collector(name: "b").tap { |c| c.save!; c.disable! } }

    it "active filters to active rows" do
      expect(described_class.active.pluck(:id)).to contain_exactly(active_one.id)
    end

    it "disabled filters to disabled rows" do
      expect(described_class.disabled.pluck(:id)).to contain_exactly(disabled_one.id)
    end

    it "for_account scopes by account" do
      other_acct = Account.where.not(id: account.id).first || account
      next if other_acct == account

      expect(described_class.for_account(account).pluck(:id))
        .to contain_exactly(active_one.id, disabled_one.id)
    end
  end

  describe "#target_endpoint" do
    it "renders host:port for IPv4" do
      c = build_collector(host: "10.0.0.1", port: 4739)
      expect(c.target_endpoint).to eq("10.0.0.1:4739")
    end

    it "brackets IPv6 hosts so the colon doesn't collide with port" do
      c = build_collector(host: "fd00::1", port: 4739)
      expect(c.target_endpoint).to eq("[fd00::1]:4739")
    end
  end
end
