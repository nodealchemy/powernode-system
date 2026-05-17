# frozen_string_literal: true

# P4.1 — Per-pair capability policy. Each FederationPeer pair declares
# (per resource kind) which direction data flows + what policy gates the
# flow + filter predicates + conflict-resolution strategy.
#
# Default is empty (no capability rows = no automatic flow); operators
# opt in resource kinds explicitly at handshake time or post-hoc.
#
# Plan reference: Decentralized Federation §D + P4.1.
class CreateSystemFederationCapabilities < ActiveRecord::Migration[8.0]
  def change
    create_table :system_federation_capabilities, id: :uuid do |t|
      t.references :account,
        type: :uuid, null: false,
        foreign_key: { to_table: :accounts, on_delete: :cascade },
        index: false
      t.references :federation_peer,
        type: :uuid, null: false,
        foreign_key: { to_table: :sdwan_federation_peers, on_delete: :cascade },
        index: false  # superseded by composite below

      t.string :resource_kind,        null: false, limit: 64
      t.string :direction,            null: false, limit: 32
      t.string :policy,               null: false, default: "manual", limit: 32
      t.string :conflict_resolution,  null: false, default: "newer_wins_logical_clock", limit: 48

      t.jsonb :filter,        null: false, default: {}
      t.jsonb :sync_cursor,   null: false, default: {}

      t.datetime :last_synced_at

      t.timestamps
    end

    add_index :system_federation_capabilities,
      %i[federation_peer_id resource_kind direction],
      unique: true,
      name: "idx_fed_caps_peer_kind_direction_unique"

    add_index :system_federation_capabilities,
      %i[account_id resource_kind],
      name: "idx_fed_caps_account_resource_kind"

    add_index :system_federation_capabilities, :policy

    add_check_constraint :system_federation_capabilities,
      "direction IN ('push_local_to_remote', 'pull_remote_to_local', 'bidirectional', 'migration_only')",
      name: "federation_capabilities_direction_enum"

    add_check_constraint :system_federation_capabilities,
      "policy IN ('manual', 'auto_on_change', 'auto_periodic', 'on_match_filter')",
      name: "federation_capabilities_policy_enum"

    add_check_constraint :system_federation_capabilities,
      "conflict_resolution IN ('newer_wins_logical_clock', 'local_wins', 'remote_wins', 'prompt')",
      name: "federation_capabilities_conflict_resolution_enum"
  end
end
