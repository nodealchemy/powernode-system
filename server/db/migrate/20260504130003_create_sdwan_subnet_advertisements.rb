# frozen_string_literal: true

# Slice 9a of the SDWAN plan — observed/declared route history.
#
# Captures every prefix being advertised inside the SDWAN — both the
# slice 9a static "operator declared this lan_subnet on this peer" rows
# AND the slice 9c "BGP learned this prefix from peer X via path Y" rows.
# The single table covers both because the operator UI surfaces them
# uniformly: a `LearnedRoutesTable.tsx` shows declared + learned + VIP
# advertisements together, with the `source` column doing the discrimination.
class CreateSdwanSubnetAdvertisements < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_subnet_advertisements, id: :uuid do |t|
      t.references :sdwan_peer, null: false, type: :uuid, foreign_key: true
      t.references :sdwan_network, null: false, type: :uuid, foreign_key: true
      t.references :account, null: false, type: :uuid, foreign_key: true

      t.string  :prefix, null: false  # CIDR (v4 or v6)

      # declared_lan_subnet — operator declared via Sdwan::Peer.lan_subnets (slice 9a)
      # virtual_ip          — the VIP machinery (slice 9b) advertises here
      # learned_via_bgp     — FRR learned from a neighbor (slice 9c)
      t.string  :source, null: false

      # When source = learned_via_bgp:
      t.uuid    :origin_peer_id     # the originator (could be self for declared)
      t.uuid    :via_peer_id        # next hop in AS_PATH (nil for self-originated)
      t.text    :as_path
      t.integer :med
      t.integer :local_pref

      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.datetime :withdrawn_at

      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    # Hot lookup paths for the operator UI:
    add_index :sdwan_subnet_advertisements, %i[sdwan_network_id prefix]
    add_index :sdwan_subnet_advertisements, %i[sdwan_peer_id source]
    add_index :sdwan_subnet_advertisements, :source
    add_index :sdwan_subnet_advertisements, :withdrawn_at  # active-only filter is common

    # GIN-style: a CIDR contains-search ("which advertisements cover 10.50.5.10?")
    # uses Postgres CIDR operators; keeping prefix as a plain string for v1.
    # Slice 9d may revisit if the operator UI needs ip_in_prefix lookups.
  end
end
