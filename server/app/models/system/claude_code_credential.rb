# frozen_string_literal: true

module System
  # One Claude Code CLI credential (Anthropic API key) per NodeInstance,
  # consumed by the claude-tmux NodeModule's boot-time fetch script over
  # the mTLS-authenticated node_api. Prefers Vault; falls back to an
  # encrypted_credentials column (Security::CredentialEncryptionService,
  # via the VaultCredential concern's default DB-fallback path) on
  # Vault-less deployments (e.g. ops-hub, POWERNODE_CA_MODE=local) — same
  # shape as System::AcmeDnsCredential.
  class ClaudeCodeCredential < ApplicationRecord
    self.table_name = "system_claude_code_credentials"

    include VaultCredential

    self.vault_credential_type = "claude_code_api_key"

    # The VaultCredential concern assumes a generic `vault_path` column;
    # this table names it `vault_path_credentials` (same alias pattern as
    # System::AcmeDnsCredential) so multi-path callers can coexist.
    alias_attribute :vault_path, :vault_path_credentials

    belongs_to :node_instance, class_name: "System::NodeInstance"
    delegate :account, :account_id, to: :node_instance

    validates :node_instance_id, uniqueness: true
  end
end
