# frozen_string_literal: true

# Sdwan::VrfBackfillService — IMP-07014982a6d3: IMP-64684f9a0ae6 (commit
# 3bd50ff) wired Sdwan::VrfAllocator into PeerEnroller so every NEW
# enrollment gets a HostVrfAssignment, but that hook only fires at
# enrollment time. Peers created before that fix have no HVA, so
# TopologyCompiler#vrf_name_for still resolves to "" for them — their
# VIPs black-hole and iBGP still has no `router bgp vrf` block, exactly
# the failure IMP-64684f9a0ae6 fixed going forward. This service is the
# one-time (idempotent — safe to re-run) backfill for that pre-existing
# fleet, invoked via `rake sdwan:backfill_host_vrf_assignments`.
#
# Every Sdwan::Peer needs a VRF regardless of its current handshake
# status — TopologyCompiler doesn't gate VRF emission on peer.status
# (see vrf_name_for), so a pending/degraded/disconnected peer still
# needs the row ready for when it does handshake.
module Sdwan
  class VrfBackfillService
    Result = Struct.new(:backfilled_count, :errors, keyword_init: true)

    def self.call
      new.call
    end

    def call
      backfilled = 0
      errors = []

      ::Sdwan::Peer.includes(:node_instance, :network).find_each do |peer|
        next if ::Sdwan::HostVrfAssignment.exists?(
          node_instance_id: peer.node_instance_id, sdwan_network_id: peer.sdwan_network_id
        )

        begin
          ::Sdwan::VrfAllocator.allocate_and_activate!(host: peer.node_instance, network: peer.network)
          backfilled += 1
        rescue StandardError => e
          errors << "peer=#{peer.id} node_instance=#{peer.node_instance_id} network=#{peer.sdwan_network_id}: #{e.class}: #{e.message}"
        end
      end

      Result.new(backfilled_count: backfilled, errors: errors)
    end
  end
end
