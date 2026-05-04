# frozen_string_literal: true

# Slice 9a of the SDWAN plan — per-peer external prefixes.
#
# `lan_subnets` is the operator-declared list of CIDRs the peer can reach
# on its LAN side. The compiler folds these into other peers' AllowedIPs
# (static mode) or hands them to FRR for BGP advertisement (ibgp mode).
#
# Slice 9c columns ship now (still nullable) so the slice 9c migration
# is purely additive on top of this one — no schema churn between sub-slices.
class AddLanSubnetsToSdwanPeers < ActiveRecord::Migration[8.1]
  def change
    add_column :sdwan_peers, :lan_subnets, :string, array: true, default: []
    # Slice 9c columns — populated only when network is in iBGP mode.
    add_column :sdwan_peers, :bgp_router_id_override, :string
    add_column :sdwan_peers, :bgp_route_reflector_client, :boolean, default: false, null: false
    add_column :sdwan_peers, :bgp_local_pref_override, :integer
    add_column :sdwan_peers, :bgp_peer_group, :string
    add_column :sdwan_peers, :bgp_session_state, :jsonb, default: {}, null: false

    add_index :sdwan_peers, :bgp_route_reflector_client
    add_index :sdwan_peers, :bgp_peer_group
    # GIN index on lan_subnets to make "which peer announces this prefix?"
    # lookups fast (used by the LearnedRoutesTable filter UI in slice 9d).
    execute "CREATE INDEX index_sdwan_peers_on_lan_subnets ON sdwan_peers USING GIN (lan_subnets)"
  end
end
