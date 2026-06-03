# frozen_string_literal: true

# AI/MCP workload substrate L2.5 (A2A) — holder for the per-account Ed25519
# signing key that seals peer CAPABILITY TOKENS (instance A may invoke skill S
# on instance B). Mirrors sdwan_constellation_signing_keys: public half is
# column-stored (not secret); the private half lives in Vault at `vault_path`
# (with `encrypted_credentials` as the DB fallback), per the VaultCredential
# concern. Distinct key from the SDWAN constellation key — different security
# domain, never shared.
class CreateSystemPeerCapabilitySigningKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :system_peer_capability_signing_keys, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true

      # Signer lookup key — "a2a-cap-acct-<short-account-id>". Unique per
      # account so the signer can find_or_create_by(account, handle). Also the
      # envelope `iss` + the handle the agent's verifier trusts a pubkey under.
      t.string :handle, null: false

      # Base64 raw Ed25519 public key (32 bytes -> 44 chars). Public, so
      # column-stored; advertised to agents for offline verification.
      t.string :public_key_b64, null: false

      # VaultCredential plumbing — private half in Vault, encrypted DB fallback.
      t.string   :vault_path
      t.text     :encrypted_credentials
      t.datetime :migrated_to_vault_at

      t.jsonb :metadata, null: false, default: {}

      # Rotation / revocation.
      t.references :rotated_from, type: :uuid, foreign_key: { to_table: :system_peer_capability_signing_keys }
      t.datetime :revoked_at
      t.string   :revocation_reason

      t.timestamps
    end

    add_index :system_peer_capability_signing_keys, %i[account_id handle], unique: true
  end
end
