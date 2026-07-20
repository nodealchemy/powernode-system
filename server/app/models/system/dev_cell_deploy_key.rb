# frozen_string_literal: true

module System
  # One per-instance Gitea deploy key per dev-cell NodeInstance. The Ed25519
  # keypair is generated in-service (System::DevCell::SshKeyGenerator); the
  # PRIVATE half is stored via Vault when available, returned to the cell
  # ONLY in the dev_cell_bootstrap mTLS response body. Prefers Vault; falls
  # back to an encrypted_credentials column (Security::CredentialEncryptionService,
  # via the VaultCredential concern's default DB-fallback path) on
  # Vault-less deployments (e.g. ops-hub, POWERNODE_CA_MODE=local) — same
  # shape as System::ClaudeCodeCredential / System::AcmeDnsCredential.
  #
  # The public, non-secret columns (public_key_openssh, fingerprint,
  # deploy_key_id, source_repo, title) exist to drive idempotent
  # rotate-on-bootstrap and remote-key revocation without ever touching the
  # private material.
  class DevCellDeployKey < ApplicationRecord
    self.table_name = "system_dev_cell_deploy_keys"

    include VaultCredential

    self.vault_credential_type = "dev_cell_deploy_key"

    # The VaultCredential concern + Security::VaultCredentialProvider assume a
    # generic `vault_path` column; this table names it `vault_path_credentials`
    # (same alias pattern as System::AcmeDnsCredential / ClaudeCodeCredential)
    # so the concern's `record.vault_path` / `vault_path?` dispatch to the real
    # column (the after_destroy :cleanup_vault_secret hook needs the predicate).
    alias_attribute :vault_path, :vault_path_credentials

    belongs_to :node_instance, class_name: "System::NodeInstance"
    delegate :account, :account_id, to: :node_instance

    validates :node_instance_id, uniqueness: true

    # Standard find-gitea-credential convention (shared with the bootstrap
    # service): the Gitea *provider* row is shared (unscoped), the *credential*
    # is scoped to the calling account. Single home so creation + revocation
    # resolve the same credential.
    def self.gitea_credential_for(account)
      provider = ::Devops::GitProvider.find_by(provider_type: "gitea")
      return nil unless provider

      account.git_provider_credentials
             .where(git_provider_id: provider.id, is_active: true)
             .order(is_default: :desc, created_at: :desc)
             .first
    end

    # Revoke the dev-cell's deploy key when its instance is recycled/terminated:
    # delete the read-write deploy key from the source repo and drop the Vault
    # private key (destroy → after_destroy :cleanup_vault_secret). Best-effort:
    # a missing record is a no-op. Wired into
    # System::ProvisioningService#finalize_termination!.
    def self.revoke_for!(node_instance)
      record = find_by(node_instance_id: node_instance.id)
      return { revoked: false, reason: "not_found" } unless record

      record.revoke!
    end

    # Delete the remote Gitea deploy key first (so a live read-write key can
    # never outlive the instance), then destroy the row — which triggers the
    # concern's Vault-secret cleanup.
    def revoke!
      delete_remote_deploy_key
      destroy!
      { revoked: true }
    end

    private

    def delete_remote_deploy_key
      return if deploy_key_id.blank? || source_repo.blank?

      credential = self.class.gitea_credential_for(account)
      return unless credential

      owner, repo = source_repo.split("/", 2)
      return if owner.blank? || repo.blank?

      ::Devops::Git::ApiClient.for(credential).delete_deploy_key(owner, repo, deploy_key_id)
    rescue ::Devops::Git::ApiClient::ApiError => e
      Rails.logger.warn(
        "[DevCellDeployKey] remote deploy-key delete failed for instance #{node_instance_id}: #{e.message}"
      )
    end
  end
end
