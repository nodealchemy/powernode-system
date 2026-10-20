# frozen_string_literal: true

# IMP-5c6a03c3b335 (D4 review F1) - at most ONE open operator key per instance,
# enforced by the database. BootstrapToken.issue! already revokes the prior open
# key (expired ones included) before inserting; this index is the backstop for
# two concurrent mints that both read "no prior" under READ COMMITTED.
#
# Any pre-existing duplicate open operator keys (none are expected: the purpose
# is new) are resolved first by revoking all but the newest, purging their
# sealed copies, so the index can always be built.
class AddOpenOperatorKeyUniqueIndexToSystemBootstrapTokens < ActiveRecord::Migration[8.1]
  INDEX = "index_system_bootstrap_tokens_one_open_operator_key"

  def up
    execute <<~SQL.squish
      UPDATE system_bootstrap_tokens t
         SET revoked_at = NOW(), sealed_plaintext = NULL, updated_at = NOW()
       WHERE t.purpose = 'operator_key' AND t.consumed_at IS NULL AND t.revoked_at IS NULL
         AND t.node_instance_id IS NOT NULL
         AND EXISTS (SELECT 1 FROM system_bootstrap_tokens n
                      WHERE n.node_instance_id = t.node_instance_id AND n.purpose = 'operator_key'
                        AND n.consumed_at IS NULL AND n.revoked_at IS NULL AND n.id > t.id)
    SQL
    return if index_exists?(:system_bootstrap_tokens, :node_instance_id, name: INDEX)

    add_index :system_bootstrap_tokens, :node_instance_id, unique: true, name: INDEX,
              where: "purpose = 'operator_key' AND consumed_at IS NULL AND revoked_at IS NULL"
  end

  def down
    remove_index :system_bootstrap_tokens, name: INDEX if index_exists?(:system_bootstrap_tokens, :node_instance_id, name: INDEX)
  end
end
