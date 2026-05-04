# frozen_string_literal: true

# Sdwan::UserDevice — a single WireGuard client config issued to a user.
# Each user can hold multiple devices per grant (laptop, phone, tablet).
# The keypair is generated server-side (default path) and stored
# Vault-first via the VaultCredential concern; the BYO-pubkey path is
# deferred to slice 4.5 — for v1 of user VPN, the operator-driven
# generate-and-distribute flow covers the common case.
#
# Slice 4 of the SDWAN plan.
class CreateSdwanUserDevices < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_user_devices, id: :uuid do |t|
      t.references :sdwan_access_grant, null: false, type: :uuid, foreign_key: true

      # Free-form operator-supplied label ("alex's laptop", "phone").
      t.string :label, null: false

      # base64 X25519 public key — column-stored (it's not secret).
      t.string :public_key, null: false

      # /128 address inside the parent network's /64. Distinct from peer
      # addresses (which derive from peer.id) — user devices derive from
      # device.id so the host-bit reverse-lookup works the same way.
      t.string :assigned_address, null: false

      # VaultCredential plumbing — vault_credential_type "wireguard_user_key".
      t.string  :vault_path
      t.text    :encrypted_credentials
      t.datetime :migrated_to_vault_at

      # Bootstrap URL is one-shot. last_downloaded_at: when the user (or
      # operator on their behalf) actually fetched the config. Once set,
      # subsequent /bootstrap requests return 410 Gone.
      t.datetime :last_downloaded_at

      # last_seen_at is updated by the platform when wg-show output on the
      # hub indicates a recent handshake from this device's pubkey.
      # (Slice 4 ships the column; slice 5's reachability sensor wires it.)
      t.datetime :last_seen_at

      t.datetime :revoked_at
      t.string   :revocation_reason

      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :sdwan_user_devices, %i[sdwan_access_grant_id label], unique: true
    add_index :sdwan_user_devices, :public_key, unique: true
    add_index :sdwan_user_devices, :assigned_address, unique: true
    add_index :sdwan_user_devices, :revoked_at
  end
end
