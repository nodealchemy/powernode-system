# frozen_string_literal: true

# Per-peer WireGuard private key, stored Vault-first via the VaultCredential
# concern (vault_credential_type: "wireguard_node_key"). Rotation creates a
# new row pointing at the previous via rotated_from_id — mirrors the
# NodeCertificate rotation chain so audits read identically.
#
# Public key lives on the row (it's not secret); private key lives in Vault
# at the path tracked by vault_path; encrypted_credentials is the DB fallback
# the VaultCredential concern uses when Vault is unavailable.
#
# Slice 1 of the SDWAN plan.
class CreateSdwanPeerKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_peer_keys, id: :uuid do |t|
      t.references :sdwan_peer, null: false, type: :uuid, foreign_key: true

      # base64-encoded X25519 public key (32 bytes → 44 chars w/ padding).
      t.string :public_key, null: false

      # VaultCredential plumbing.
      t.string  :vault_path
      t.text    :encrypted_credentials
      t.datetime :migrated_to_vault_at

      # Rotation chain. NULL on the genesis key for a peer; points at the
      # superseded row's id for each subsequent rotation.
      t.uuid :rotated_from_id

      t.datetime :revoked_at
      t.string :revocation_reason

      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    # Only one un-revoked key per peer is "current"; partial unique index
    # enforces it without blocking the audit chain.
    add_index :sdwan_peer_keys, :sdwan_peer_id,
              unique: true,
              where: "revoked_at IS NULL",
              name: "idx_sdwan_peer_keys_one_active_per_peer"
    add_index :sdwan_peer_keys, :public_key, unique: true
    add_index :sdwan_peer_keys, :rotated_from_id
    add_foreign_key :sdwan_peer_keys, :sdwan_peer_keys, column: :rotated_from_id
  end
end
