# frozen_string_literal: true

# P4.5.3 — Federation network bridges: peer × sdwan_network join with a
# state machine. Records which SDWAN networks a federation peer's
# inter-peer traffic is permitted to route over. Created at handshake
# time (proposed → active), optionally suspended by operator, terminal
# when revoked.
#
# Plan reference: Decentralized Federation §K + P4.5.3.
class CreateSystemFederationNetworkBridges < ActiveRecord::Migration[8.0]
  def change
    create_table :system_federation_network_bridges, id: :uuid do |t|
      t.references :account,
        type: :uuid, null: false,
        foreign_key: { to_table: :accounts, on_delete: :cascade },
        index: false
      t.references :federation_peer,
        type: :uuid, null: false,
        foreign_key: { to_table: :sdwan_federation_peers, on_delete: :cascade },
        index: false
      t.references :sdwan_network,
        type: :uuid, null: false,
        foreign_key: { to_table: :sdwan_networks, on_delete: :restrict }

      t.string :state, null: false, default: "proposed", limit: 16
      t.jsonb  :metadata, null: false, default: {}

      t.datetime :proposed_at
      t.datetime :activated_at
      t.datetime :suspended_at
      t.datetime :revoked_at
      t.string   :revocation_reason, limit: 256

      t.timestamps
    end

    # A (peer, network) pair is unique. Two distinct bridge records on
    # the same pair would be ambiguous; the state machine handles
    # transitions on the single row.
    add_index :system_federation_network_bridges,
      %i[federation_peer_id sdwan_network_id],
      unique: true, name: "idx_fed_bridges_peer_network_unique"

    add_index :system_federation_network_bridges, :state
    add_index :system_federation_network_bridges, %i[account_id state]

    add_check_constraint :system_federation_network_bridges,
      "state IN ('proposed', 'active', 'suspended', 'revoked')",
      name: "federation_network_bridges_state_enum"
  end
end
