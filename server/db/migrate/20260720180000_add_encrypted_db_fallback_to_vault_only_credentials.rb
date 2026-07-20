# frozen_string_literal: true

# Three VaultCredential-including models were built Vault-ONLY (no
# encrypted_credentials column): System::DevCellDeployKey,
# System::ClaudeCodeCredential, System::AcmeDnsCredential. That was meant to
# fail closed on a Vault outage, but Security::VaultCredentialProvider's
# generic DB-fallback branch (store_credential/rotate_credential) already
# fires for them today regardless — VaultCredential#credentials= always
# exists as a method, so `record.respond_to?(:credentials=)` is always true —
# it just silently no-ops (the setter early-returns when encrypted_credentials
# is absent) and returns a FALSE {stored_in: :database}, discarding the
# credential while reporting success. Adding the column makes that fallback
# path real instead of a lie, on Vault-less deployments (e.g. ops-hub,
# POWERNODE_CA_MODE=local) where these credential flows would otherwise
# silently fail. Matches the encrypted_credentials/encryption_key_id shape
# already used by System::StorageCredential and other VaultCredential
# includers.
class AddEncryptedDbFallbackToVaultOnlyCredentials < ActiveRecord::Migration[8.1]
  def change
    add_column :system_dev_cell_deploy_keys, :encrypted_credentials, :text
    add_column :system_dev_cell_deploy_keys, :encryption_key_id, :string

    add_column :system_claude_code_credentials, :encrypted_credentials, :text
    add_column :system_claude_code_credentials, :encryption_key_id, :string

    add_column :system_acme_dns_credentials, :encrypted_credentials, :text
    add_column :system_acme_dns_credentials, :encryption_key_id, :string
  end
end
