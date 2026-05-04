# frozen_string_literal: true

# Slice 9a of the SDWAN plan — per-network routing-protocol opt-in.
#
# `static` (default) compiles `Sdwan::Peer.lan_subnets` into AllowedIPs at
# topology-compile time — declarative, no daemon, perfect for fleets that
# don't churn membership often. `ibgp` (slice 9c) hands distribution off to
# FRR running on each peer.
#
# Existing slice 1-8 networks default to `static` so this migration is a
# pure no-op for in-flight deployments.
class AddRoutingProtocolToSdwanNetworks < ActiveRecord::Migration[8.1]
  def change
    add_column :sdwan_networks, :routing_protocol, :string, default: "static", null: false
    add_column :sdwan_networks, :advertise_overlay_subnet, :boolean, default: true, null: false
    # How many hubs in this network should run as iBGP route reflectors.
    # Used by slice 9f sensors to flag insufficient redundancy. Meaningful
    # only when routing_protocol = "ibgp"; harmless to set in static mode.
    add_column :sdwan_networks, :route_reflector_redundancy, :integer, default: 1, null: false

    add_index :sdwan_networks, :routing_protocol
  end
end
