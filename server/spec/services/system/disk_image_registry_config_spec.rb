# frozen_string_literal: true

require "rails_helper"

# DK1 restoration — registry config resolver. Host is platform config
# (AdminSetting); user/token are real credentials (Security::SecretStore,
# platform-global account: nil). ENV is the dev-only fallback tier.
RSpec.describe System::DiskImageRegistryConfig, type: :service do
  before do
    AdminSetting.where(key: described_class::HOST_SETTING_KEY).delete_all
    Security::Secret.where(scope: described_class::SECRET_SCOPE).delete_all
    AdminSetting.where(key: Security::SecretStore::SETTING_KEY).delete_all # default (:database) backend
  end

  around do |example|
    original = ENV.to_hash.slice("POWERNODE_REGISTRY_HOST", "POWERNODE_REGISTRY_USER", "POWERNODE_REGISTRY_TOKEN")
    ENV.delete("POWERNODE_REGISTRY_HOST")
    ENV.delete("POWERNODE_REGISTRY_USER")
    ENV.delete("POWERNODE_REGISTRY_TOKEN")
    example.run
  ensure
    original.each { |k, v| ENV[k] = v }
  end

  describe "with nothing configured" do
    it "is not configured" do
      expect(described_class.configured?).to be(false)
    end

    it "returns nil for host/user/token" do
      expect(described_class.registry_host).to be_nil
      expect(described_class.registry_user).to be_nil
      expect(described_class.registry_token).to be_nil
    end
  end

  describe "AdminSetting + SecretStore populated" do
    before do
      AdminSetting.set(described_class::HOST_SETTING_KEY, "git.powernode.org")
      Security::SecretStore.write(account: nil, scope: described_class::SECRET_SCOPE, key: "registry_user", value: "ci-bot")
      Security::SecretStore.write(account: nil, scope: described_class::SECRET_SCOPE, key: "registry_token", value: "s3cr3t-token")
    end

    it "reads host from AdminSetting" do
      expect(described_class.registry_host).to eq("git.powernode.org")
    end

    it "reads credentials from SecretStore" do
      expect(described_class.registry_user).to eq("ci-bot")
      expect(described_class.registry_token).to eq("s3cr3t-token")
    end

    it "is configured" do
      expect(described_class.configured?).to be(true)
    end
  end

  describe "placeholder host" do
    before do
      AdminSetting.set(described_class::HOST_SETTING_KEY, "registry.example.com")
      Security::SecretStore.write(account: nil, scope: described_class::SECRET_SCOPE, key: "registry_user", value: "u")
      Security::SecretStore.write(account: nil, scope: described_class::SECRET_SCOPE, key: "registry_token", value: "t")
    end

    it "is NOT configured — the seed placeholder host doesn't count" do
      expect(described_class.registry_host).to eq("registry.example.com")
      expect(described_class.configured?).to be(false)
    end
  end

  describe "ENV fallback (store empty)" do
    around do |example|
      ENV["POWERNODE_REGISTRY_HOST"] = "env.registry.example.org"
      ENV["POWERNODE_REGISTRY_USER"] = "env-user"
      ENV["POWERNODE_REGISTRY_TOKEN"] = "env-token"
      example.run
    ensure
      ENV.delete("POWERNODE_REGISTRY_HOST")
      ENV.delete("POWERNODE_REGISTRY_USER")
      ENV.delete("POWERNODE_REGISTRY_TOKEN")
    end

    it "falls back to ENV when AdminSetting/SecretStore are empty" do
      expect(described_class.registry_host).to eq("env.registry.example.org")
      expect(described_class.registry_user).to eq("env-user")
      expect(described_class.registry_token).to eq("env-token")
      expect(described_class.configured?).to be(true)
    end
  end

  describe "never outages: a store read failure falls back to ENV" do
    around do |example|
      ENV["POWERNODE_REGISTRY_TOKEN"] = "env-token-fallback"
      example.run
    ensure
      ENV.delete("POWERNODE_REGISTRY_TOKEN")
    end

    it "logs a warning and returns the ENV value instead of raising" do
      allow(Security::SecretStore).to receive(:read).and_raise(Security::SecretStore::BackendUnavailable, "vault down")
      expect(Rails.logger).to receive(:warn).with(/SecretStore read failed for registry_token/)
      expect(described_class.registry_token).to eq("env-token-fallback")
    end
  end
end
