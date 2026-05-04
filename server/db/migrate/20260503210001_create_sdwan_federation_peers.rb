# frozen_string_literal: true

# Sdwan::FederationPeer — forward-compat scaffold for cross-Powernode-instance
# overlay peering. v1 is data-only: the model exists, the governance scanner
# checks for prefix overlap, the topology compiler accepts a federation_resolver
# hook that always returns [] in v1. Cross-CA signing, remote API calls, JWT
# verification — all deferred to a future slice.
#
# Closes the "federation-ready" claim at minimal LOC. The cost of NOT shipping
# this scaffold is that a future federation slice would force a migration mid-
# rollout; the cost of shipping it now is ~80 LOC and one new permission.
#
# Slice 6 of the SDWAN plan (we-are-continuing-development-spicy-bear.md).
class CreateSdwanFederationPeers < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_federation_peers, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true

      # Remote-instance identity. URL is the platform endpoint operators
      # use to reach the federated instance; remote_instance_id is the
      # opaque UUID it self-identifies as. We DON'T resolve the URL or
      # validate the ID in v1 — both are operator-supplied attestations.
      t.string :remote_instance_url,  null: false
      t.uuid   :remote_instance_id
      t.uuid   :remote_account_id

      # The remote /48 prefix. Used by FederationGovernance#scan to detect
      # overlap with our own install prefix. Format validation only —
      # slice 6 doesn't actually route packets to remote prefixes.
      t.string :remote_prefix_advertisement

      # Trust JWT — VaultCredential stored. The JWT carries the remote
      # instance's signed claim of ownership over remote_prefix_advertisement.
      # In v1 we store it but never verify it; future federation activates
      # cross-CA verification.
      t.string  :vault_path
      t.text    :encrypted_credentials
      t.datetime :migrated_to_vault_at

      # proposed → accepted (operator-validated) → active (handshake
      # established, slice-future) → suspended (operator-paused) → revoked.
      # v1 only allows proposed and revoked transitions; intermediate
      # states ship now so future slices can flip rows in-place.
      t.string :status, default: "proposed", null: false

      t.datetime :signed_at
      t.datetime :expires_at

      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :sdwan_federation_peers, %i[account_id remote_instance_id], unique: true,
              name: "idx_sdwan_federation_peers_unique_remote"
    add_index :sdwan_federation_peers, :status
    add_index :sdwan_federation_peers, :remote_prefix_advertisement
  end
end
