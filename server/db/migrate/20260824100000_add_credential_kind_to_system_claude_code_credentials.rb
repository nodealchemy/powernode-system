# frozen_string_literal: true

# OAuth (Claude subscription) support for the claude-tmux NodeModule:
# a System::ClaudeCodeCredential row is now either an Anthropic API key
# ("api_key", the original and default kind) or a Claude Code OAuth
# credential blob ("oauth" — the ~/.claude/.credentials.json shape).
# The kind is DECLARED by the producer (operator POST) and stored here so
# neither the node_api read path nor the on-node fetch script ever has to
# infer it from the Vault payload's key shape.
class AddCredentialKindToSystemClaudeCodeCredentials < ActiveRecord::Migration[8.1]
  def change
    add_column :system_claude_code_credentials, :credential_kind, :string,
               null: false, default: "api_key"
  end
end
