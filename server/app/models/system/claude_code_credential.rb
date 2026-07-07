# frozen_string_literal: true

module System
  # One Claude Code CLI credential (Anthropic API key) per NodeInstance,
  # consumed by the claude-tmux NodeModule's boot-time fetch script over
  # the mTLS-authenticated node_api. Vault-only storage — mirrors
  # System::AcmeDnsCredential's design (no encrypted_credentials column,
  # so there is no plaintext DB fallback for this secret).
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
