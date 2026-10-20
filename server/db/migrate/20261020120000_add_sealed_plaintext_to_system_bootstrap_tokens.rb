# frozen_string_literal: true

# IMP-5c6a03c3b335 (D4) - operator-issued enrolment keys (purpose operator_key)
# keep a recoverable copy of the plaintext so a gated reveal verb can hand it
# back. The column holds ActiveRecord::Encryption ciphertext (the model's
# `encrypts :sealed_plaintext`), never the key itself, and is set to NULL when
# the key is consumed or revoked.
#
# Guarded by column_exists? because server/db/schema.rb carries the system tables:
# a database built with db:schema:load can still see this migration as pending.
class AddSealedPlaintextToSystemBootstrapTokens < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:system_bootstrap_tokens, :sealed_plaintext)

    add_column :system_bootstrap_tokens, :sealed_plaintext, :text
  end

  def down
    remove_column :system_bootstrap_tokens, :sealed_plaintext if column_exists?(:system_bootstrap_tokens, :sealed_plaintext)
  end
end
