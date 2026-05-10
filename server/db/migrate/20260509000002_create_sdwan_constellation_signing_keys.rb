# frozen_string_literal: true

# Forward-compat holder for the Ed25519 signing key that seals every
# Sdwan::MembershipCredential. In N0 there is exactly one row per
# account ("default" constellation per account); in N2 the
# Sdwan::Constellation table will own a `belongs_to :signing_key`
# pointing here, allowing operators to manage multiple constellations
# per account.
#
# The row exists to satisfy the VaultCredential concern's storage
# contract: every credential type requires an AR record so the Vault
# path + DB-fallback encryption have somewhere to land. The public_key
# is column-stored (it isn't secret); the private key lives in Vault
# at the path tracked by `vault_path`, with `encrypted_credentials`
# as the local fallback.
#
# Phase N0 of the in-house encrypted mesh overlay roadmap.
class CreateSdwanConstellationSigningKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_constellation_signing_keys, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true

      # Stable identifier the signer uses to look up this key. In N0
      # this is "acct-<short-account-id>"; N2 swaps the value for a
      # constellation handle. Unique per account so the signer can
      # find_or_create_by(account, handle).
      t.string :handle, null: false

      # Base64-encoded raw Ed25519 public key (32 bytes → 44 chars).
      # Public, so column-stored. Used by the agent's mc_verifier to
      # validate envelope signatures.
      t.string :public_key_b64, null: false

      # VaultCredential plumbing. Private half lives in Vault; DB
      # fallback when Vault is unavailable.
      t.string  :vault_path
      t.text    :encrypted_credentials
      t.datetime :migrated_to_vault_at

      # Rotation chain — N5+ may rotate constellation keys. NULL on
      # genesis row; mirrors Sdwan::PeerKey's rotation pattern.
      t.uuid :rotated_from_id
      t.datetime :revoked_at
      t.string :revocation_reason

      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :sdwan_constellation_signing_keys, %i[account_id handle],
              unique: true,
              name: "idx_sdwan_constellation_keys_acct_handle"
    add_index :sdwan_constellation_signing_keys, :rotated_from_id
    add_foreign_key :sdwan_constellation_signing_keys, :sdwan_constellation_signing_keys,
                    column: :rotated_from_id
  end
end
