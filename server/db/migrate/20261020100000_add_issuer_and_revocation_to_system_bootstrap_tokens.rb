# frozen_string_literal: true

# IMP-cde9ee63c977 (D2) - operator-issued enrolment keys are System::BootstrapToken
# rows (purpose operator_key). They need an issuer and a revocation record:
#
#   created_by_id  - the user who issued the key; NULL for machine issuers
#                    (provider seeds, netboot, federation). ON DELETE NULLIFY so
#                    deleting a user never deletes the audit-bearing token row.
#   revoked_at     - set by BootstrapToken#revoke!; a revoked token is never
#                    redeemable and never in the `active` scope.
#   revoked_by_id  - the user who revoked it (NULL for machine revocation).
#
# Guarded by column_exists? because server/db/schema.rb carries the system tables:
# a database built with db:schema:load can still see this migration as pending.
class AddIssuerAndRevocationToSystemBootstrapTokens < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:system_bootstrap_tokens, :created_by_id)
      add_reference :system_bootstrap_tokens, :created_by, type: :uuid, null: true,
                    foreign_key: { to_table: :users, on_delete: :nullify }
    end
    unless column_exists?(:system_bootstrap_tokens, :revoked_by_id)
      add_reference :system_bootstrap_tokens, :revoked_by, type: :uuid, null: true,
                    foreign_key: { to_table: :users, on_delete: :nullify }
    end
    add_column :system_bootstrap_tokens, :revoked_at, :datetime unless column_exists?(:system_bootstrap_tokens, :revoked_at)
    add_index :system_bootstrap_tokens, :revoked_at unless index_exists?(:system_bootstrap_tokens, :revoked_at)
  end

  def down
    remove_index :system_bootstrap_tokens, :revoked_at if index_exists?(:system_bootstrap_tokens, :revoked_at)
    remove_column :system_bootstrap_tokens, :revoked_at if column_exists?(:system_bootstrap_tokens, :revoked_at)
    remove_reference :system_bootstrap_tokens, :revoked_by, foreign_key: { to_table: :users } if column_exists?(:system_bootstrap_tokens, :revoked_by_id)
    remove_reference :system_bootstrap_tokens, :created_by, foreign_key: { to_table: :users } if column_exists?(:system_bootstrap_tokens, :created_by_id)
  end
end
