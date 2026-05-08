# frozen_string_literal: true

# M1 Self-Serve Hardening — System::ProviderCredential
#
# Cloud-credential storage per-account (account_owned) or shared
# platform-pool (account_id NULL). Mirrors the LLM-cred sibling at
# server/app/models/ai/provider_credential.rb but uses Rails 7 attribute
# encryption directly on the `credentials` text column rather than the
# legacy attr_encrypted-style `_ciphertext`/`_iv` pair (per the
# encrypts_round_trip_spec convention from the M0.H rename).
#
# Lookup precedence: account_owned wins over platform_pool — see
# System::ProviderCredential.for(account:, provider:).
class CreateSystemProviderCredentials < ActiveRecord::Migration[8.0]
  def change
    create_table :system_provider_credentials, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # nil for platform_pool scope; account_id required for account_owned
      t.references :account, type: :uuid, foreign_key: true, null: true

      t.references :provider, type: :uuid, null: false,
                   foreign_key: { to_table: :system_providers }

      t.string :name, null: false

      # Rails 7 `encrypts :credentials` writes the encrypted ciphertext
      # directly into this text column. JSON-serialized hash inside.
      t.text :credentials

      # 0 = account_owned, 1 = platform_pool
      t.integer :scope, null: false, default: 0

      t.boolean :is_active, null: false, default: true

      # Health/test telemetry — mirrors Ai::ProviderCredential shape so
      # cred-management UI can be unified across LLM + cloud creds.
      t.string :last_test_status
      t.datetime :last_test_at
      t.text :last_error
      t.integer :consecutive_failures, null: false, default: 0

      t.timestamps
    end

    # Composite scoped index — account_owned uniqueness is enforced at the
    # validation layer (one active cred per account+provider), but the
    # partial index speeds the .for() lookup.
    add_index :system_provider_credentials, [:account_id, :provider_id],
              where: "scope = 0",
              name: "idx_system_provider_creds_account_owned"

    # Lookup by scope is hot (platform_pool fallback resolution).
    add_index :system_provider_credentials, :scope
  end
end
