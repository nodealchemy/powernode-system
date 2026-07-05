# frozen_string_literal: true

require "rails_helper"

# DK1 restoration — registry config resolver. Host is platform config
# (AdminSetting); user/token are real credentials (Security::SecretStore,
# platform-global account: nil). ENV is the dev-only fallback tier.
#
# DK4 adds a fourth, lowest-precedence tier: the calling account's own Gitea
# provider credential (Devops::GitProviderCredential) — so a fresh account
# needs zero hand-entered registry secrets as long as it already has a Gitea
# credential connected. All resolver methods now take `account:`.
RSpec.describe System::DiskImageRegistryConfig, type: :service do
  let(:account) { create(:account) }

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

  describe "with nothing configured and no Gitea provider" do
    it "is not configured" do
      expect(described_class.configured?(account: account)).to be(false)
    end

    it "returns nil for host/user/token" do
      expect(described_class.registry_host(account: account)).to be_nil
      expect(described_class.registry_user(account: account)).to be_nil
      expect(described_class.registry_token(account: account)).to be_nil
    end
  end

  describe "AdminSetting + SecretStore populated (override tier)" do
    before do
      AdminSetting.set(described_class::HOST_SETTING_KEY, "git.powernode.org")
      Security::SecretStore.write(account: nil, scope: described_class::SECRET_SCOPE, key: "registry_user", value: "ci-bot")
      Security::SecretStore.write(account: nil, scope: described_class::SECRET_SCOPE, key: "registry_token", value: "s3cr3t-token")
    end

    it "reads host from AdminSetting" do
      expect(described_class.registry_host(account: account)).to eq("git.powernode.org")
    end

    it "reads credentials from SecretStore" do
      expect(described_class.registry_user(account: account)).to eq("ci-bot")
      expect(described_class.registry_token(account: account)).to eq("s3cr3t-token")
    end

    it "is configured" do
      expect(described_class.configured?(account: account)).to be(true)
    end
  end

  describe "placeholder host" do
    before do
      AdminSetting.set(described_class::HOST_SETTING_KEY, "registry.example.com")
      Security::SecretStore.write(account: nil, scope: described_class::SECRET_SCOPE, key: "registry_user", value: "u")
      Security::SecretStore.write(account: nil, scope: described_class::SECRET_SCOPE, key: "registry_token", value: "t")
    end

    it "is NOT configured — the seed placeholder host doesn't count" do
      expect(described_class.registry_host(account: account)).to eq("registry.example.com")
      expect(described_class.configured?(account: account)).to be(false)
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
      expect(described_class.registry_host(account: account)).to eq("env.registry.example.org")
      expect(described_class.registry_user(account: account)).to eq("env-user")
      expect(described_class.registry_token(account: account)).to eq("env-token")
      expect(described_class.configured?(account: account)).to be(true)
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
      expect(described_class.registry_token(account: account)).to eq("env-token-fallback")
    end
  end

  describe "Gitea provider credential fallback (DK4, no override/ENV set)" do
    let!(:gitea_provider) { create(:git_provider, :gitea, web_base_url: "https://git.powernode.org") }
    let!(:credential) do
      create(:git_provider_credential, :gitea,
             provider: gitea_provider,
             account: account,
             external_username: "opuser",
             encrypted_credentials: Base64.strict_encode64({ "access_token" => "gitea-derived-token" }.to_json))
    end

    it "derives the host from the Gitea provider's effective_web_base_url" do
      expect(described_class.registry_host(account: account)).to eq("git.powernode.org")
    end

    it "derives the user from the credential's external_username" do
      expect(described_class.registry_user(account: account)).to eq("opuser")
    end

    it "derives the token from the credential's access_token" do
      expect(described_class.registry_token(account: account)).to eq("gitea-derived-token")
    end

    it "is configured purely from the Gitea credential — zero hand-entered secrets" do
      expect(described_class.configured?(account: account)).to be(true)
    end

    it "scopes the credential lookup to the given account — a different account with no credential gets nothing" do
      other_account = create(:account)
      expect(described_class.registry_user(account: other_account)).to be_nil
      expect(described_class.registry_token(account: other_account)).to be_nil
    end

    it "falls back through credentials hash / user email when external_username is blank" do
      credential.update_column(:external_username, nil)
      expect(described_class.registry_user(account: account)).to eq(credential.user.email.split("@").first)
    end
  end

  describe "override precedence still wins over a Gitea credential" do
    let!(:gitea_provider) { create(:git_provider, :gitea, web_base_url: "https://git.powernode.org") }
    let!(:credential) do
      create(:git_provider_credential, :gitea, provider: gitea_provider, account: account, external_username: "opuser")
    end

    before do
      AdminSetting.set(described_class::HOST_SETTING_KEY, "override.registry.example.org")
      Security::SecretStore.write(account: nil, scope: described_class::SECRET_SCOPE, key: "registry_user", value: "override-user")
      Security::SecretStore.write(account: nil, scope: described_class::SECRET_SCOPE, key: "registry_token", value: "override-token")
    end

    it "prefers the override over the Gitea-derived values" do
      expect(described_class.registry_host(account: account)).to eq("override.registry.example.org")
      expect(described_class.registry_user(account: account)).to eq("override-user")
      expect(described_class.registry_token(account: account)).to eq("override-token")
    end
  end

  # IMP-e7e4595d3fa6 — full scheme+host Gitea base URL, needed by callers
  # (ModuleBuildDispatchService::GiteaDispatchAdapter) that hit the Gitea
  # REST API directly rather than just building an OCI ref host.
  describe ".gitea_web_base_url" do
    it "returns nil when no Gitea provider is configured" do
      expect(described_class.gitea_web_base_url).to be_nil
    end

    it "returns the full scheme+host URL of the configured Gitea provider" do
      create(:git_provider, :gitea, web_base_url: "https://git.powernode.org")
      expect(described_class.gitea_web_base_url).to eq("https://git.powernode.org")
    end
  end

  describe "an inactive Gitea credential is not used" do
    let!(:gitea_provider) { create(:git_provider, :gitea, web_base_url: "https://git.powernode.org") }

    it "does not resolve user/token from an inactive credential" do
      create(:git_provider_credential, :gitea, :inactive, provider: gitea_provider, account: account, external_username: "opuser")

      expect(described_class.registry_user(account: account)).to be_nil
      expect(described_class.registry_token(account: account)).to be_nil
    end
  end
end
