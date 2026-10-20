# frozen_string_literal: true

# IMP-5c6a03c3b335 (D4 review F1) - at most ONE open operator key per instance,
# enforced by the database. BootstrapToken.issue! already revokes the prior open
# key (expired ones included) before inserting; this index is the backstop for
# two concurrent mints that both read "no prior" under READ COMMITTED.
#
# This migration NEVER mutates data: revoking a key is an audited, fail-closed
# key operation and a raw UPDATE would skip the audit row. If duplicate open
# operator keys already exist the migration ABORTS and tells the operator to
# revoke them through the audited path first (REST DELETE or the MCP
# system_revoke_bootstrap_token verb); re-run afterwards. Fully reversible.
class AddOpenOperatorKeyUniqueIndexToSystemBootstrapTokens < ActiveRecord::Migration[8.1]
  INDEX = "index_system_bootstrap_tokens_one_open_operator_key"

  class DuplicateOpenOperatorKeys < StandardError; end

  def up
    duplicates = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM (
        SELECT node_instance_id FROM system_bootstrap_tokens
         WHERE purpose = 'operator_key' AND consumed_at IS NULL AND revoked_at IS NULL
           AND node_instance_id IS NOT NULL
         GROUP BY node_instance_id HAVING COUNT(*) > 1
      ) d
    SQL
    if duplicates.positive?
      raise DuplicateOpenOperatorKeys,
            "#{duplicates} instance(s) have more than one open operator key. Revoke the extras through the " \
            "audited path (REST DELETE .../bootstrap_tokens/:id or the system_revoke_bootstrap_token MCP verb), " \
            "then re-run this migration. Nothing was changed."
    end
    return if index_exists?(:system_bootstrap_tokens, :node_instance_id, name: INDEX)

    add_index :system_bootstrap_tokens, :node_instance_id, unique: true, name: INDEX,
              where: "purpose = 'operator_key' AND consumed_at IS NULL AND revoked_at IS NULL"
  end

  def down
    remove_index :system_bootstrap_tokens, name: INDEX if index_exists?(:system_bootstrap_tokens, :node_instance_id, name: INDEX)
  end
end
