# frozen_string_literal: true

# P4.2 — Cross-peer access grants. The substrate for sovereign-auth
# federation: alice@A grants bob@B read access to her Skill X (or any
# kind+id combination). Bearer-tokenized at the federation_api layer
# (`Authorization: Bearer fg-<grant_id>`).
#
# TTL defaults to 30 days (configurable; minimum 7 days enforced at model
# level). Revoked grants soft-delete with 90-day retention before archival
# (per Fix 3 of the architectural evaluation).
#
# Plan reference: Decentralized Federation §E + P4.2.
class CreateSystemFederationGrants < ActiveRecord::Migration[8.0]
  def change
    create_table :system_federation_grants, id: :uuid do |t|
      t.references :account,
        type: :uuid, null: false,
        foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :federation_peer,
        type: :uuid, null: false,
        foreign_key: { to_table: :sdwan_federation_peers, on_delete: :cascade }
      t.references :grantor_user,
        type: :uuid, null: false,
        foreign_key: { to_table: :users, on_delete: :restrict }

      # Opaque identifier the remote peer presents (e.g. "bob@platform-b").
      # We don't validate the format — peers may use opaque UUIDs or
      # email-style strings; the remote_subject is informational here
      # (the mTLS cert + grant_id is what actually authenticates).
      t.string :remote_subject, null: false, limit: 256

      t.string :resource_kind, null: false, limit: 64

      # nullable — when nil, the grant covers ALL resources of `resource_kind`
      # (e.g., "read on every skill"). When set, grant is to that one record.
      t.uuid :resource_id

      t.jsonb :permission_scopes, null: false, default: []

      t.datetime :issued_at,  null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.string   :revocation_reason, limit: 256
      t.datetime :archived_at

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    # Two partial unique indices: one when resource_id is present (grant
    # to a specific record), one when null (grant to all of kind). Avoids
    # duplicate-grant rows while permitting both a kind-wide grant AND
    # specific-resource grants to coexist.
    add_index :system_federation_grants,
      %i[federation_peer_id remote_subject resource_kind resource_id],
      unique: true,
      where: "resource_id IS NOT NULL",
      name: "idx_fed_grants_specific_resource_unique"

    add_index :system_federation_grants,
      %i[federation_peer_id remote_subject resource_kind],
      unique: true,
      where: "resource_id IS NULL",
      name: "idx_fed_grants_kind_wide_unique"

    add_index :system_federation_grants, %i[account_id expires_at],
      where: "revoked_at IS NULL AND archived_at IS NULL",
      name: "idx_fed_grants_account_expiring"

    add_index :system_federation_grants, %i[account_id revoked_at],
      where: "archived_at IS NULL",
      name: "idx_fed_grants_account_revoked"
  end
end
