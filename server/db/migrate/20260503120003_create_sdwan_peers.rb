# frozen_string_literal: true

# Sdwan::Peer is a *membership* record, not a tunnel-edge record. Edges are
# emergent from the topology strategy (Sdwan::TopologyStrategies::HubAndSpoke
# in v1, FullMesh in v2 with no schema change). The model carries the peer's
# /128 address, public-reachability flag, and the cached compiler outputs
# the agent reads from /node_api/config/sdwan.
#
# Slice 1 of the SDWAN plan.
class CreateSdwanPeers < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_peers, id: :uuid do |t|
      t.references :sdwan_network, null: false, type: :uuid,
                   foreign_key: true
      t.references :node_instance, null: false, type: :uuid,
                   foreign_key: { to_table: :system_node_instances }
      t.references :account, null: false, type: :uuid, foreign_key: true

      # /128 carved deterministically from peer.id. Stored on the row so that
      # a `wg show`-style debug session can reverse-resolve an address to a
      # peer without walking the ID hash.
      t.string :assigned_address, null: false

      # If true, this peer is a hub: spokes use endpoint_host:endpoint_port to
      # reach it, and the hub forwards intra-network traffic via AllowedIPs
      # covering the network's /64. Hub-and-spoke v1 requires at least one.
      t.boolean :publicly_reachable, default: false, null: false
      t.string :endpoint_host
      t.integer :endpoint_port
      t.integer :listen_port, default: 51820, null: false

      # pending → active when the agent reports a recent handshake.
      # degraded → active loop on transient packet loss; disconnected when
      # >5min without a handshake.
      t.string :status, default: "pending", null: false

      t.datetime :last_handshake_at
      t.datetime :last_compiled_at

      # Mirrors NodeInstancePeer.capabilities.sdwan: { wg_pubkey, mtu,
      # supported_protocols, ... }. Compiler reads from here on every emit.
      t.jsonb :capabilities, default: {}, null: false
      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    # A node_instance can join the same network at most once.
    add_index :sdwan_peers, [:sdwan_network_id, :node_instance_id], unique: true
    add_index :sdwan_peers, [:account_id, :assigned_address], unique: true
    add_index :sdwan_peers, :status
    add_index :sdwan_peers, :publicly_reachable
  end
end
