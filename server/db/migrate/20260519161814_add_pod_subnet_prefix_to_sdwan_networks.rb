# frozen_string_literal: true

# Adds the `pod_subnet_prefix` column to sdwan_networks so K3s flannel pod
# traffic can be routed over the SDWAN WireGuard overlay (via flannel
# host-gw + the existing AllowedIPs covering the network's /64).
#
# When the column is null (default), nothing changes — existing networks
# keep flannel's default behavior (VXLAN over host primary NIC). When the
# column is set, the routing pipeline + bootstrap_config endpoint emit the
# extra flannel install args (`--flannel-iface`, `--flannel-backend=host-gw`,
# `--cluster-cidr`) and the SDWAN compiler folds the prefix into peer
# AllowedIPs + BGP announce sets for K3s-running peers.
#
# Validation + overlap detection live on the Sdwan::Network model; the
# column itself is unconstrained at the DB layer to allow future schema
# evolution (e.g., promoting to a typed inet column once IPv4/IPv6 split
# semantics stabilize).
class AddPodSubnetPrefixToSdwanNetworks < ActiveRecord::Migration[8.1]
  def change
    add_column :sdwan_networks, :pod_subnet_prefix, :string
  end
end
