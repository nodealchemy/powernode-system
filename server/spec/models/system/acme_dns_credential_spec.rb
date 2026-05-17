# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::AcmeDnsCredential, type: :model do
  let(:account) { create(:account) }

  describe "validations" do
    it "requires name + provider + status" do
      cred = described_class.new(account: account)
      expect(cred).not_to be_valid
      expect(cred.errors[:name]).to be_present
    end

    it "enforces provider whitelist" do
      cred = build(:system_acme_dns_credential, account: account, provider: "bogus-dns")
      expect(cred).not_to be_valid
      expect(cred.errors[:provider]).to be_present
    end

    it "accepts every supported provider" do
      described_class::SUPPORTED_PROVIDERS.each do |provider|
        cred = build(:system_acme_dns_credential, account: account, provider: provider)
        expect(cred).to be_valid, "expected provider #{provider.inspect} to validate"
      end
    end

    it "enforces unique name within an account" do
      create(:system_acme_dns_credential, account: account, name: "primary")
      dup = build(:system_acme_dns_credential, account: account, name: "primary")
      expect(dup).not_to be_valid
      expect(dup.errors[:name]).to be_present
    end

    it "allows the same name across different accounts" do
      other_account = create(:account)
      create(:system_acme_dns_credential, account: account, name: "primary")
      other = build(:system_acme_dns_credential, account: other_account, name: "primary")
      expect(other).to be_valid
    end
  end

  describe "freshness predicates" do
    it "needs_revalidation? true when last_validated_at is nil" do
      cred = build(:system_acme_dns_credential, last_validated_at: nil)
      expect(cred.needs_revalidation?).to be true
    end

    it "needs_revalidation? false when recently validated" do
      cred = build(:system_acme_dns_credential, last_validated_at: 1.hour.ago)
      expect(cred.needs_revalidation?).to be false
    end

    it "needs_revalidation? true when older than freshness window" do
      cred = build(:system_acme_dns_credential, last_validated_at: 48.hours.ago)
      expect(cred.needs_revalidation?).to be true
    end
  end

  describe "mark_validated! / mark_invalid!" do
    let(:cred) { create(:system_acme_dns_credential, account: account, status: "untested") }

    it "mark_validated! flips status + sets timestamp" do
      cred.mark_validated!
      expect(cred.status).to eq("valid")
      expect(cred.last_validated_at).to be_present
      expect(cred.provider_credentials_valid?).to be true
    end

    it "mark_invalid! records the reason" do
      cred.mark_invalid!(reason: "API token rejected (401)")
      expect(cred.status).to eq("invalid")
      expect(cred.metadata["invalid_reason"]).to include("API token rejected")
    end
  end

  describe "scopes" do
    let!(:fresh)   { create(:system_acme_dns_credential, :valid, account: account, last_validated_at: 1.hour.ago) }
    let!(:stale)   { create(:system_acme_dns_credential, :valid, account: account, last_validated_at: 48.hours.ago) }
    let!(:invalid_cred) { create(:system_acme_dns_credential, :invalid, account: account) }

    it ".valid_creds returns only status=valid" do
      ids = described_class.valid_creds.pluck(:id)
      expect(ids).to include(fresh.id, stale.id)
      expect(ids).not_to include(invalid_cred.id)
    end

    it ".needs_revalidation returns only stale-validation rows" do
      # invalid_cred has last_validated_at = Time.current (the :invalid
      # trait just-validated-and-found-bad), so it does NOT need
      # revalidation by the time-based scope — only `stale` does.
      ids = described_class.needs_revalidation.pluck(:id)
      expect(ids).to include(stale.id)
      expect(ids).not_to include(fresh.id, invalid_cred.id)
    end
  end
end
