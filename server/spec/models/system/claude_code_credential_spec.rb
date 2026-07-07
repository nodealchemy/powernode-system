# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::ClaudeCodeCredential, type: :model do
  describe "associations" do
    it "belongs to a node_instance and delegates account through it" do
      credential = create(:system_claude_code_credential)
      expect(credential.node_instance).to be_a(System::NodeInstance)
      expect(credential.account).to eq(credential.node_instance.account)
      expect(credential.account_id).to eq(credential.node_instance.account_id)
    end
  end

  describe "validations" do
    it "enforces one credential per node_instance" do
      instance = create(:system_node_instance)
      create(:system_claude_code_credential, node_instance: instance)
      duplicate = build(:system_claude_code_credential, node_instance: instance)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:node_instance_id]).to be_present
    end
  end

  describe "VaultCredential concern wiring" do
    it "uses the claude_code_api_key credential type" do
      expect(described_class.vault_credential_type).to eq("claude_code_api_key")
    end

    it "aliases vault_path to the vault_path_credentials column" do
      credential = build(:system_claude_code_credential)
      credential.vault_path = "system/claude-code-api-keys/some-id"
      expect(credential.vault_path_credentials).to eq("system/claude-code-api-keys/some-id")
    end

    it "has no encrypted_credentials column (Vault-only, no plaintext DB fallback)" do
      expect(described_class.column_names).not_to include("encrypted_credentials")
    end
  end
end
