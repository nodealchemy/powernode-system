# frozen_string_literal: true

# Sdwan::BgpSession — observed live state of an iBGP session between two
# peers in the same network. Written by the heartbeat reporter (agent's
# frr_observer parses `vtysh -c "show bgp summary json"`); never written
# by operators. The Sdwan::TopologyCompiler reads these to surface live
# connectivity in the operator UI.
#
# Slice 9c of the SDWAN plan.
class CreateSdwanBgpSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_bgp_sessions, id: :uuid do |t|
      t.references :sdwan_peer, null: false, type: :uuid, foreign_key: true
      t.references :sdwan_network, null: false, type: :uuid, foreign_key: true
      t.references :neighbor_peer, type: :uuid, foreign_key: { to_table: :sdwan_peers }

      t.string :neighbor_address, null: false  # overlay /128 of remote end

      # idle|connect|active|opensent|openconfirm|established
      t.string :state, null: false, default: "idle"

      t.integer :uptime_seconds, default: 0
      t.integer :prefixes_received, default: 0
      t.integer :prefixes_sent, default: 0
      t.datetime :last_state_change_at
      t.string :last_error
      t.datetime :last_observed_at, null: false

      t.timestamps
    end

    add_index :sdwan_bgp_sessions,
              %i[sdwan_peer_id neighbor_address],
              unique: true,
              name: "idx_sdwan_bgp_sessions_unique_local_remote"
    add_index :sdwan_bgp_sessions, :state
  end
end
