# frozen_string_literal: true

require "rails_helper"

# SECURITY: these specs assert the storage wiring + revocation behaviour.
# They NEVER assert a private key value, and confirm the DB-fallback path
# (used on Vault-less deployments) only ever holds the key encrypted, never
# plaintext.
RSpec.describe System::DevCellDeployKey, type: :model do
  let(:instance) { create(:system_node_instance) }

  describe "associations" do
    it "belongs to a node_instance and delegates account through it" do
      record = described_class.create!(node_instance: instance)
      expect(record.node_instance).to be_a(System::NodeInstance)
      expect(record.account).to eq(instance.account)
      expect(record.account_id).to eq(instance.account_id)
    end
  end

  describe "validations" do
    it "enforces one deploy key per node_instance" do
      described_class.create!(node_instance: instance)
      duplicate = described_class.new(node_instance: instance)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:node_instance_id]).to be_present
    end
  end

  describe "VaultCredential concern wiring" do
    it "uses the dev_cell_deploy_key credential type" do
      expect(described_class.vault_credential_type).to eq("dev_cell_deploy_key")
    end

    it "aliases vault_path to the vault_path_credentials column" do
      record = described_class.new(node_instance: instance)
      record.vault_path = "system/dev-cell-deploy-keys/some-id"
      expect(record.vault_path_credentials).to eq("system/dev-cell-deploy-keys/some-id")
    end

  end

  describe "#store_in_vault" do
    it "routes the private key to the Vault credential provider and never a DB column, when Vault succeeds" do
      record = described_class.create!(node_instance: instance)
      provider = instance_double(Security::VaultCredentialProvider)
      allow(Security::VaultCredentialProvider).to receive(:new).and_return(provider)
      expect(provider).to receive(:store_credential).with(
        hash_including(credential_type: "dev_cell_deploy_key", credential_id: record.id)
      ).and_return({ stored_in: :vault, path: "system/dev-cell-deploy-keys/#{record.id}" })

      record.store_in_vault("private_key_openssh" => "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----\n")

      # The private key must not have landed in any DB-backed attribute.
      expect(record.attributes.values.map(&:to_s)).not_to include(a_string_including("OPENSSH PRIVATE KEY"))
    end

    it "encrypts the private key at rest via encrypted_credentials on the Vault-less DB fallback path" do
      record = described_class.create!(node_instance: instance)
      plaintext = "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----\n"

      result = record.store_in_vault("private_key_openssh" => plaintext)

      expect(result[:stored_in]).to eq(:database)
      expect(record.reload.encrypted_credentials).to be_present
      expect(record.encrypted_credentials).not_to include("OPENSSH PRIVATE KEY")
      expect(record.credentials["private_key_openssh"]).to eq(plaintext)
    end
  end

  describe ".gitea_credential_for" do
    let(:gitea_provider) { create(:git_provider, :gitea, account: instance.account) }

    it "resolves the account-scoped active gitea credential" do
      cred = create(:git_provider_credential, account: instance.account, provider: gitea_provider)
      expect(described_class.gitea_credential_for(instance.account)).to eq(cred)
    end

    it "returns nil when the account has no active gitea credential" do
      create(:git_provider_credential, account: instance.account, provider: gitea_provider, is_active: false)
      expect(described_class.gitea_credential_for(instance.account)).to be_nil
    end
  end

  describe ".revoke_for!" do
    let(:gitea_provider) { create(:git_provider, :gitea, account: instance.account) }
    let!(:gitea_credential) { create(:git_provider_credential, account: instance.account, provider: gitea_provider) }
    let(:fake_client) { instance_double("Devops::Git::GiteaApiClient") }

    before { allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake_client) }

    it "deletes the remote deploy key and destroys the row" do
      record = described_class.create!(
        node_instance: instance,
        source_repo: "powernode/powernode-platform",
        deploy_key_id: 7,
        title: "dev-cell-#{instance.id}"
      )
      expect(fake_client).to receive(:delete_deploy_key).with("powernode", "powernode-platform", 7)
        .and_return({ success: true })

      expect { described_class.revoke_for!(instance) }
        .to change { described_class.exists?(record.id) }.from(true).to(false)
    end

    it "is a no-op when no deploy key exists for the instance" do
      expect(described_class.revoke_for!(instance)).to eq(revoked: false, reason: "not_found")
    end
  end
end
