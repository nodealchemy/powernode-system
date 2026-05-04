# frozen_string_literal: true

# Slice 7a of the SDWAN plan — dual-stack hub endpoints.
#
# Adds endpoint_host_v6 + endpoint_host_v4 alongside the existing
# endpoint_host (kept for backward compat). New code prefers the
# split fields; the legacy column is read-fall-through only.
#
# WireGuard's [Peer] section accepts only ONE Endpoint per peer, so the
# compiler chooses the primary (v6 when present, else v4) and ships the
# alternative as a separate `fallback_endpoint` field in the agent
# payload. The agent uses the fallback when v6 reachability sensors
# (slice 5 SdwanReachabilitySensor) flag the primary as dead.
class AddDualStackEndpointsToSdwanPeers < ActiveRecord::Migration[8.1]
  def change
    add_column :sdwan_peers, :endpoint_host_v6, :string
    add_column :sdwan_peers, :endpoint_host_v4, :string

    # Indexed because the per-family compiler emit + UI filter both lookup
    # by family. Cheap; rows are ~hundreds per network at most.
    add_index :sdwan_peers, :endpoint_host_v6
    add_index :sdwan_peers, :endpoint_host_v4
  end
end
