# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::ProviderCredential, type: :model do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  # Account.after_create_commit auto-bootstraps a "Pro Cloud" provider, so
  # reuse it rather than creating a duplicate (which would trip the
  # name-uniqueness validation scoped to account_id).
  let(:provider) do
    ::System::Provider.find_by(account: account, provider_type: "pro_cloud") ||
      create(:system_provider, account: account, provider_type: "pro_cloud", name: "Pro Cloud Test")
  end

  let(:valid_creds) { { "api_key" => "test-secret-#{SecureRandom.hex(8)}" } }

  describe "associations" do
    it { is_expected.to belong_to(:account).optional }
    it { is_expected.to belong_to(:provider).class_name("::System::Provider") }
  end

  describe "validations" do
    it "requires a name" do
      cred = described_class.new(provider: provider, account: account, credentials: valid_creds, scope: :account_owned)
      cred.name = nil
      expect(cred).not_to be_valid
      expect(cred.errors[:name]).to be_present
    end

    it "requires non-blank credentials" do
      cred = described_class.new(provider: provider, account: account, name: "default", scope: :account_owned)
      cred.credentials = nil
      expect(cred).not_to be_valid
      expect(cred.errors[:credentials]).to be_present

      cred.credentials = {}
      expect(cred).not_to be_valid
      expect(cred.errors[:credentials]).to be_present
    end

    context "scope-aware account validation" do
      it "requires account_id when account_owned" do
        cred = described_class.new(
          provider: provider, account: nil, name: "default", credentials: valid_creds, scope: :account_owned
        )
        expect(cred).not_to be_valid
        expect(cred.errors[:account_id]).to be_present
      end

      it "forbids account_id when platform_pool" do
        cred = described_class.new(
          provider: provider, account: account, name: "platform-default",
          credentials: valid_creds, scope: :platform_pool
        )
        expect(cred).not_to be_valid
        expect(cred.errors[:account_id]).to be_present
      end

      it "accepts platform_pool with no account" do
        cred = described_class.new(
          provider: provider, account: nil, name: "platform-default",
          credentials: valid_creds, scope: :platform_pool
        )
        expect(cred).to be_valid
      end
    end
  end

  describe "scope enum" do
    it "maps account_owned to 0 and platform_pool to 1" do
      expect(described_class.scopes).to eq("account_owned" => 0, "platform_pool" => 1)
    end

    it "round-trips through the database" do
      cred = described_class.create!(
        provider: provider, account: account, name: "default",
        credentials: valid_creds, scope: :account_owned
      )
      expect(cred.reload.account_owned?).to be true

      pool = described_class.create!(
        provider: provider, account: nil, name: "pool",
        credentials: valid_creds, scope: :platform_pool
      )
      expect(pool.reload.platform_pool?).to be true
    end
  end

  describe "encryption round-trip" do
    it "persists credentials hash through reload" do
      cred = described_class.create!(
        provider: provider, account: account, name: "default",
        credentials: { "api_key" => "rotation-1", "region" => "us-east" },
        scope: :account_owned
      )
      cred.reload
      expect(cred.credentials).to eq("api_key" => "rotation-1", "region" => "us-east")
    end

    it "stores ciphertext on disk, not plaintext" do
      described_class.create!(
        provider: provider, account: account, name: "default",
        credentials: { "api_key" => "plaintext-marker-xyz" },
        scope: :account_owned
      )
      raw = described_class.connection.select_value(
        "SELECT credentials FROM system_provider_credentials WHERE name = 'default'"
      )
      expect(raw).to be_present
      expect(raw).not_to include("plaintext-marker-xyz")
    end
  end

  describe ".for(account:, provider:)" do
    it "returns the account_owned cred when both scopes exist (precedence wins)" do
      pool = described_class.create!(
        provider: provider, account: nil, name: "pool",
        credentials: { "api_key" => "pool-key" }, scope: :platform_pool
      )
      owned = described_class.create!(
        provider: provider, account: account, name: "owned",
        credentials: { "api_key" => "owned-key" }, scope: :account_owned
      )

      result = described_class.for(account: account, provider: provider)
      expect(result).to eq(owned)
      expect(result).not_to eq(pool)
    end

    it "falls back to platform_pool when no account_owned exists" do
      pool = described_class.create!(
        provider: provider, account: nil, name: "pool",
        credentials: { "api_key" => "pool-key" }, scope: :platform_pool
      )

      expect(described_class.for(account: account, provider: provider)).to eq(pool)
    end

    it "returns nil when no cred exists" do
      expect(described_class.for(account: account, provider: provider)).to be_nil
    end

    it "ignores inactive account_owned creds and falls through to platform_pool" do
      described_class.create!(
        provider: provider, account: account, name: "owned-disabled",
        credentials: { "api_key" => "x" }, scope: :account_owned, is_active: false
      )
      pool = described_class.create!(
        provider: provider, account: nil, name: "pool",
        credentials: { "api_key" => "pool-key" }, scope: :platform_pool
      )

      expect(described_class.for(account: account, provider: provider)).to eq(pool)
    end

    it "scopes account_owned correctly across accounts" do
      described_class.create!(
        provider: provider, account: account, name: "owned",
        credentials: { "api_key" => "for-acct" }, scope: :account_owned
      )

      # other_account shouldn't see acct's cred (also no platform_pool)
      expect(described_class.for(account: other_account, provider: provider)).to be_nil
    end
  end

  describe "#record_success! / #record_failure!" do
    let(:cred) do
      described_class.create!(
        provider: provider, account: account, name: "default",
        credentials: valid_creds, scope: :account_owned
      )
    end

    it "tracks success state" do
      cred.update!(consecutive_failures: 3, last_error: "boom", is_active: false)
      cred.record_success!
      expect(cred.reload.consecutive_failures).to eq(0)
      expect(cred.last_error).to be_nil
      expect(cred.last_test_status).to eq("success")
      expect(cred.is_active).to be true
    end

    it "tracks failures and auto-disables after 5" do
      6.times { cred.record_failure!("err") }
      expect(cred.reload.consecutive_failures).to eq(6)
      expect(cred.is_active).to be false
    end
  end
end
