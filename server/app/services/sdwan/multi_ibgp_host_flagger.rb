# frozen_string_literal: true

# Sdwan::MultiIbgpHostFlagger — IMP-2f34679b6b73.
#
# FRR is ONE host-wide daemon. A host that joins two or more iBGP networks
# runs both fabrics inside one FRR, separated only by Linux VRFs (see
# Sdwan::Bgp::ConfigCompiler#render_per_vrf_bgp_blocks, which emits one
# `router bgp <as> vrf <name>` block per host VRF). That is fine for the
# CONFIG side. It is not fine for the OBSERVATION side unless the agent's
# vtysh poll names the VRF: an unscoped `show bgp summary` answers for one
# routing context and says nothing about the others, so replaying it under
# every network id credits each network with another network's sessions.
#
# Two things live here, and the split matters:
#
#   ibgp_network_count — the PREDICATE's input, computed from live rows.
#                  This is what Sdwan::BgpSessionWriter gates on. It cannot
#                  be stale and it needs no backfill, so a host that was
#                  already multi-iBGP before this shipped is handled
#                  correctly on the first tick.
#
#   the flag     — PROVENANCE, persisted on every one of the host's peers
#                  under bgp_session_state["multi_ibgp_host"]. It records
#                  WHEN the host entered this shape, which no live query can
#                  reconstruct, and the sensor escalates on that age: a
#                  misattribution that has been standing for a day is worse
#                  than one that started an hour ago.
#
# The flag is refreshed from the enrollment seam (Sdwan::PeerEnroller) and,
# for removal, from an after_commit on Sdwan::Peer itself rather than from
# Sdwan::PeerDetacher alone — peers are also destroyed by
# Sdwan::Executors::DeletePeer, by several composition skills, and by
# `Sdwan::Network has_many :peers, dependent: :destroy`. A flag that
# outlived its condition would keep the sensor's escalation firing for a
# host that is no longer multi-iBGP.
module Sdwan
  class MultiIbgpHostFlagger
    KEY = "multi_ibgp_host"
    RISK = "bgp_observation_requires_vrf_scope"

    def self.refresh!(node_instance:)
      new(node_instance: node_instance).refresh!
    end

    # The predicate's raw input. Live rows, no stamp involved — this is what
    # Sdwan::BgpSessionWriter gates on, so a host that was already multi-iBGP
    # before this shipped needs no backfill to be handled correctly.
    def self.ibgp_network_count(node_instance_id:)
      return 0 if node_instance_id.blank?

      ::Sdwan::Peer.joins(:network)
                   .where(node_instance_id: node_instance_id,
                          system_sdwan_networks: { routing_protocol: "ibgp" })
                   .distinct.count(:sdwan_network_id)
    end

    # Provenance read: the stamp, or nil when the host was never stamped (one
    # that predates this change, or one flagged then unflagged). Its
    # "flagged_at" is what SdwanBgpSessionHealthSensor escalates on.
    def self.flag_for(peer)
      return nil unless peer.respond_to?(:bgp_session_state)
      return nil unless peer.bgp_session_state.is_a?(Hash)

      flag = peer.bgp_session_state[KEY]
      flag.is_a?(Hash) ? flag : nil
    end

    # Set ONE top-level key of a peer's bgp_session_state without reading the
    # rest of the document first. Two writers touch this column from
    # different request cycles — the agent's per-tick observation stamp and
    # this class's enrollment stamp — and a read-modify-write of the whole
    # jsonb from either one silently erases whatever the other wrote in the
    # interval.
    def self.merge_key!(peer_id:, key:, value:)
      ::Sdwan::Peer.where(id: peer_id).update_all([
        "bgp_session_state = jsonb_set(COALESCE(bgp_session_state, '{}'::jsonb), ARRAY[?], ?::jsonb, true)",
        key, value.to_json
      ])
    end

    def self.delete_key!(peer_id:, key:)
      ::Sdwan::Peer.where(id: peer_id).update_all([
        "bgp_session_state = COALESCE(bgp_session_state, '{}'::jsonb) - ?", key
      ])
    end

    def initialize(node_instance:)
      @node_instance = node_instance
    end

    # Recomputes the host's iBGP membership and stamps (or clears) the flag
    # on every one of its SDWAN peers. Idempotent: an unchanged membership
    # set leaves flagged_at alone, so the stamp records when the host FIRST
    # entered this shape rather than when it was last looked at.
    def refresh!
      return [] if node_instance_id.blank?

      peers = host_peers
      return [] if peers.empty?

      ibgp_network_ids = peers.select { |p| ibgp?(p) }.map(&:sdwan_network_id).uniq.sort
      multi = ibgp_network_ids.size >= 2

      peers.each do |peer|
        existing = self.class.flag_for(peer)

        if multi
          next if existing && Array(existing["network_ids"]) == ibgp_network_ids

          self.class.merge_key!(peer_id: peer.id, key: KEY, value: {
            "network_ids" => ibgp_network_ids,
            "flagged_at"  => flagged_at_for(existing),
            "risk"        => RISK
          })
        else
          next if existing.nil?

          self.class.delete_key!(peer_id: peer.id, key: KEY)
        end
      end

      ibgp_network_ids
    end

    private

    def node_instance_id
      @node_instance_id ||= @node_instance.is_a?(String) ? @node_instance : @node_instance&.id
    end

    # Preserve the original stamp when the host was already flagged; the
    # membership set changing (a third network joins) is still the same
    # standing condition.
    def flagged_at_for(existing)
      return existing["flagged_at"] if existing.is_a?(Hash) && existing["flagged_at"].present?

      Time.current.utc.iso8601
    end

    def host_peers
      ::Sdwan::Peer.includes(:network).where(node_instance_id: node_instance_id).to_a
    end

    def ibgp?(peer)
      network = peer.network
      network.respond_to?(:ibgp_routing?) && network.ibgp_routing?
    end
  end
end
