# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::RoutePolicy, type: :model do
  let(:account) { Account.first || create(:account) }

  let(:valid_statements) do
    [
      { "match" => { "prefix_in" => ["10.0.0.0/8"] },
        "action" => { "type" => "accept", "set_local_pref" => 200 } }
    ]
  end

  describe "validations" do
    it "is valid with account scope + minimum statement set" do
      p = described_class.new(account_id: account.id, name: "ok-#{SecureRandom.hex(3)}",
                              scope: "account", direction: "import", statements: valid_statements)
      expect(p).to be_valid
    end

    it "rejects unknown match keys" do
      p = described_class.new(account_id: account.id, name: "bad-match-#{SecureRandom.hex(3)}",
                              scope: "account", direction: "import",
                              statements: [{ "match" => { "weird_match" => "x" },
                                             "action" => { "type" => "accept" } }])
      expect(p).not_to be_valid
      expect(p.errors[:statements].join).to match(/unknown match key/)
    end

    it "rejects unknown action keys" do
      p = described_class.new(account_id: account.id, name: "bad-action-#{SecureRandom.hex(3)}",
                              scope: "account", direction: "import",
                              statements: [{ "match" => {},
                                             "action" => { "type" => "accept", "set_super_pref" => 999 } }])
      expect(p).not_to be_valid
      expect(p.errors[:statements].join).to match(/unknown action key/)
    end

    it "requires action.type on every statement" do
      p = described_class.new(account_id: account.id, name: "no-type-#{SecureRandom.hex(3)}",
                              scope: "account", direction: "import",
                              statements: [{ "match" => {}, "action" => { "set_local_pref" => 100 } }])
      expect(p).not_to be_valid
      expect(p.errors[:statements].join).to match(/action.type is required/)
    end

    it "rejects empty statement arrays" do
      p = described_class.new(account_id: account.id, name: "empty-#{SecureRandom.hex(3)}",
                              scope: "account", direction: "import", statements: [])
      expect(p).not_to be_valid
      expect(p.errors[:statements].join).to match(/cannot be empty/)
    end

    it "requires scope_resource_id when scope=network or scope=peer" do
      p = described_class.new(account_id: account.id, name: "missing-res-#{SecureRandom.hex(3)}",
                              scope: "network", direction: "import", statements: valid_statements)
      expect(p).not_to be_valid
      expect(p.errors[:scope_resource_id].join).to match(/must be set when scope=network/)
    end

    it "rejects scope_resource_id when scope=account" do
      p = described_class.new(account_id: account.id, name: "extra-res-#{SecureRandom.hex(3)}",
                              scope: "account", scope_resource_id: SecureRandom.uuid,
                              direction: "import", statements: valid_statements)
      expect(p).not_to be_valid
      expect(p.errors[:scope_resource_id].join).to match(/must be null when scope=account/)
    end

    it "validates direction enum" do
      p = described_class.new(account_id: account.id, name: "bad-dir-#{SecureRandom.hex(3)}",
                              scope: "account", direction: "sideways", statements: valid_statements)
      expect(p).not_to be_valid
      expect(p.errors[:direction]).to be_present
    end
  end

  describe "#slug" do
    it "produces an FRR-safe identifier prefixed with pn- and the policy id slice" do
      p = described_class.create!(account_id: account.id, name: "Prefer Internal!  ",
                                  scope: "account", direction: "import", statements: valid_statements)
      expect(p.slug).to match(/\Apn-[0-9a-f]{8}-prefer-internal\z/)
    end
  end
end
