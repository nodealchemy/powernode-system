# frozen_string_literal: true

# Sdwan::PortMapping — operator-declared DNAT rules on a hub peer that
# publish a service running on a target peer to the hub's v4 underlay
# address. The classic v4-only-client-reaches-overlay-service use case.
#
# Wire format: tcp/udp <listen_port> on hub → target_peer's overlay
# /128 on <target_port>. The agent's nat_applier.go writes these as
# nft DNAT rules into the per-network `sdwan_nat_<8>` chain.
#
# Slice 7b of the SDWAN plan.
class CreateSdwanPortMappings < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_port_mappings, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true
      t.references :sdwan_network, null: false, type: :uuid, foreign_key: true
      # The hub peer that hosts the public listen socket.
      t.references :sdwan_peer,  null: false, type: :uuid, foreign_key: true
      # The target peer whose overlay service receives the DNAT'd traffic.
      t.references :target_peer, type: :uuid, foreign_key: { to_table: :sdwan_peers }

      # Slice 9b extension — port mapping can target a VIP instead of a
      # specific peer. When set, the DNAT target follows the VIP holder
      # automatically (the compiler resolves to current holder at compile time).
      t.references :target_virtual_ip, type: :uuid, foreign_key: { to_table: :sdwan_virtual_ips }

      t.string :name, null: false, limit: 64

      # Inbound (hub-side) listen port.
      t.integer :listen_port, null: false

      # Outbound (target-side) port; defaults to listen_port when nil.
      t.integer :target_port

      t.string :protocol, null: false, default: "tcp"

      t.boolean :enabled, null: false, default: true
      t.datetime :last_compiled_at

      t.string :description, limit: 255
      t.jsonb  :metadata, default: {}, null: false

      t.timestamps
    end

    # One operator-published service per (hub, listen_port, protocol)
    # tuple — collisions on the hub's underlay socket are fatal.
    add_index :sdwan_port_mappings,
              %i[sdwan_peer_id listen_port protocol],
              unique: true,
              name: "idx_sdwan_port_mappings_unique_listen"

    add_index :sdwan_port_mappings, %i[account_id sdwan_network_id]
    add_check_constraint :sdwan_port_mappings,
                         "protocol IN ('tcp', 'udp')",
                         name: "sdwan_port_mappings_protocol_enum"
    add_check_constraint :sdwan_port_mappings,
                         "listen_port BETWEEN 1 AND 65535",
                         name: "sdwan_port_mappings_listen_port_range"
    # Exactly one of target_peer_id / target_virtual_ip_id must be set.
    add_check_constraint :sdwan_port_mappings,
                         "(target_peer_id IS NOT NULL)::int + (target_virtual_ip_id IS NOT NULL)::int = 1",
                         name: "sdwan_port_mappings_exactly_one_target"
  end
end
