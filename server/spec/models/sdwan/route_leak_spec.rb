# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::RouteLeak, type: :model do
  let(:account)       { Account.first || create(:account) }
  let(:other_account) { create(:account) }

  before do
    Sdwan::RouteLeak.where(account_id: [account.id, other_account.id]).delete_all
    Sdwan::Configuration.where(account_id: [account.id, other_account.id]).delete_all
    Sdwan::Network.where(account_id: [account.id, other_account.id]).delete_all
  end

  let(:net_a) { Sdwan::Network.create!(account_id: account.id, name: "leak-a-#{SecureRandom.hex(3)}") }
  let(:net_b) { Sdwan::Network.create!(account_id: account.id, name: "leak-b-#{SecureRandom.hex(3)}") }

  def build_leak(overrides = {})
    described_class.new({
      account: account,
      source_network: net_a,
      dest_network: net_b,
      direction: "one_way",
      prefix_filter: [{ "cidr" => "fd00:abcd::/48", "action" => "permit" }]
    }.merge(overrides))
  end

  describe "validations" do
    it "is valid with a permit prefix filter" do
      expect(build_leak).to be_valid
    end

    it "rejects identical source and dest networks" do
      leak = build_leak(dest_network: net_a)
      expect(leak).not_to be_valid
      expect(leak.errors[:dest_network_id].join).to match(/differ/)
    end

    it "rejects networks that belong to different accounts" do
      foreign_net = Sdwan::Network.create!(account_id: other_account.id,
                                           name: "leak-foreign-#{SecureRandom.hex(3)}")
      leak = build_leak(dest_network: foreign_net)
      expect(leak).not_to be_valid
      expect(leak.errors[:base].join).to match(/same account/)
    end

    it "rejects unknown direction" do
      leak = build_leak(direction: "circular")
      expect(leak).not_to be_valid
      expect(leak.errors[:direction]).to be_present
    end

    it "rejects unknown state" do
      leak = build_leak(state: "limbo")
      expect(leak).not_to be_valid
      expect(leak.errors[:state]).to be_present
    end

    it "rejects malformed cidr in prefix_filter" do
      leak = build_leak(prefix_filter: [{ "cidr" => "not-a-cidr", "action" => "permit" }])
      expect(leak).not_to be_valid
      expect(leak.errors[:prefix_filter].join).to match(/CIDR/)
    end

    it "rejects unknown filter action" do
      leak = build_leak(prefix_filter: [{ "cidr" => "fd00::/64", "action" => "redirect" }])
      expect(leak).not_to be_valid
      expect(leak.errors[:prefix_filter].join).to match(/action/)
    end

    it "permits an empty prefix_filter (means leak everything)" do
      leak = build_leak(prefix_filter: [])
      expect(leak).to be_valid
    end

    it "rejects a duplicate (source, dest, direction) tuple at the model + DB level" do
      build_leak.save!
      dup = build_leak
      # AR's uniqueness validator catches this first and surfaces a
      # validation error; bypassing the validator triggers the DB-level
      # unique constraint instead.
      expect { dup.save! }.to raise_error(ActiveRecord::RecordInvalid)
      expect { dup.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "permits the reverse direction as a separate row" do
      build_leak.save!
      reverse = build_leak(source_network: net_b, dest_network: net_a)
      expect { reverse.save! }.not_to raise_error
    end
  end

  describe "AASM lifecycle" do
    let(:leak) { build_leak.tap(&:save!) }

    it "starts in :proposed" do
      expect(leak.state).to eq("proposed")
    end

    it "activate! transitions proposed → active and stamps activated_at" do
      expect { leak.activate! }.to change(leak, :state).from("proposed").to("active")
      expect(leak.activated_at).to be_present
    end

    it "revoke! transitions active → revoked and stamps revoked_at" do
      leak.activate!
      expect { leak.revoke! }.to change(leak, :state).from("active").to("revoked")
      expect(leak.revoked_at).to be_present
    end

    it "activate! on a revoked leak clears revoked_at" do
      leak.activate!
      leak.revoke!
      leak.activate!
      expect(leak.state).to eq("active")
      expect(leak.revoked_at).to be_nil
    end
  end

  describe "#directed_pairs" do
    it "returns one pair for one_way" do
      leak = build_leak.tap(&:save!)
      pairs = leak.directed_pairs
      expect(pairs.size).to eq(1)
      expect(pairs.first[:source]).to eq(net_a)
      expect(pairs.first[:dest]).to eq(net_b)
    end

    it "returns two pairs for bidirectional" do
      leak = build_leak(direction: "bidirectional").tap(&:save!)
      pairs = leak.directed_pairs
      expect(pairs.size).to eq(2)
      expect(pairs.map { |p| [p[:source].id, p[:dest].id] })
        .to contain_exactly([net_a.id, net_b.id], [net_b.id, net_a.id])
    end
  end

  describe "scopes" do
    let!(:proposed_leak) { build_leak.tap(&:save!) }
    let!(:active_leak)   { build_leak(direction: "bidirectional").tap { |l| l.save!; l.activate! } }

    it ".active filters to active rows" do
      expect(described_class.active.pluck(:id)).to contain_exactly(active_leak.id)
    end

    it ".proposed filters to proposed rows" do
      expect(described_class.proposed.pluck(:id)).to contain_exactly(proposed_leak.id)
    end

    it ".compilable returns only active rows" do
      expect(described_class.compilable.pluck(:id)).to contain_exactly(active_leak.id)
    end

    it ".touching_network catches both source and dest matches" do
      expect(described_class.touching_network(net_a).pluck(:id))
        .to contain_exactly(proposed_leak.id, active_leak.id)
    end
  end

  describe "DB-level guards" do
    it "rejects identical source/dest at the constraint level" do
      leak = build_leak
      leak.dest_network_id = leak.source_network_id
      expect { leak.save(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "rejects unknown state at the constraint level" do
      leak = build_leak.tap(&:save!)
      leak.state = "limbo"
      expect { leak.save(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end
end
