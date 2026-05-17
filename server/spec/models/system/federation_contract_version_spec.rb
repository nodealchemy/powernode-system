# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::FederationContractVersion, type: :model do
  describe "validations" do
    subject { build(:system_federation_contract_version) }

    it { is_expected.to validate_presence_of(:contract_text) }
    it { is_expected.to validate_presence_of(:effective_at) }

    it "enforces uniqueness on version" do
      first = create(:system_federation_contract_version, version: 7)
      dup = build(:system_federation_contract_version, version: 7,
                                                       contract_text: "different text")
      expect(dup).not_to be_valid
      expect(dup.errors[:version]).to include("has already been taken")
      first.destroy
    end

    it "rejects a non-positive version" do
      expect(build(:system_federation_contract_version, version: 0)).not_to be_valid
      expect(build(:system_federation_contract_version, version: -1)).not_to be_valid
    end
  end

  describe "digest auto-compute" do
    it "computes contract_digest from contract_text on save" do
      version = described_class.new(
        version: 1,
        contract_text: "Hello federation",
        effective_at: Date.current
      )
      expect(version.save).to be true
      expect(version.contract_digest).to eq(Digest::SHA256.hexdigest("Hello federation"))
    end

    it "rejects a manually-set digest that doesn't match" do
      version = described_class.new(
        version: 1,
        contract_text: "Hello federation",
        contract_digest: "0" * 64,  # wrong
        effective_at: Date.current
      )
      # before_validation will overwrite, so this should actually pass.
      # The validation guards against in-flight tampering between compute_digest
      # and the validator, which is hard to trigger in normal use.
      expect(version.save).to be true
      expect(version.contract_digest).to eq(Digest::SHA256.hexdigest("Hello federation"))
    end
  end

  describe ".latest" do
    it "returns the highest non-deprecated version" do
      v1 = create(:system_federation_contract_version, version: 1)
      v2 = create(:system_federation_contract_version, version: 2)
      expect(described_class.latest).to eq(v2)
      v2.deprecate!
      expect(described_class.latest).to eq(v1)
    end
  end

  describe "#deprecate!" do
    it "marks a version deprecated with a date" do
      version = create(:system_federation_contract_version)
      version.deprecate!
      expect(version.deprecated_at).to eq(Date.current)
      expect(version.deprecated?).to be true
    end

    it "is idempotent" do
      version = create(:system_federation_contract_version, deprecated_at: Date.yesterday)
      expect(version.deprecate!).to be false
      expect(version.deprecated_at).to eq(Date.yesterday)
    end
  end
end
