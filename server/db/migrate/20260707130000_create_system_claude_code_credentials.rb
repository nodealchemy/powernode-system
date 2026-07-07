# frozen_string_literal: true

# Increment 20 (campaign 019f3458) — one Claude Code CLI credential
# (Anthropic API key) per NodeInstance, for the claude-tmux NodeModule.
# Vault-only storage (mirrors System::AcmeDnsCredential): no
# encrypted_credentials column, so there is no plaintext DB fallback for
# this secret — a Vault outage fails closed instead of ever landing the
# key in Postgres.
class CreateSystemClaudeCodeCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :system_claude_code_credentials, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :node_instance_id, null: false
      t.string :vault_path_credentials
      t.datetime :migrated_to_vault_at

      t.timestamps
    end

    add_index :system_claude_code_credentials, :node_instance_id, unique: true
  end
end
