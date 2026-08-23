# frozen_string_literal: true

# Sdwan::BgpSessionWriter — upserts Sdwan::BgpSession rows from the
# agent's frr_observer payload. One row per (local peer, neighbor address)
# tuple; state transitions stamp last_state_change_at.
#
# Idempotent: the same payload applied twice produces the same DB state.
# Detects state transitions (idle → established, etc.) and updates
# last_state_change_at only when the state actually changes.
#
# Resolves neighbor_peer_id heuristically: if the neighbor_address matches
# the assigned_address of another peer in the same network, link it.
# Otherwise neighbor_peer_id stays nil — the dashboard still shows the
# session, just without the FK-resolved name.
#
# Slice 9f of the SDWAN plan.
#
# ── IMP-2f34679b6b73: attribution ──────────────────────────────────────
#
# FRR is one host-wide daemon. An agent that polls `vtysh show bgp summary`
# WITHOUT naming a VRF gets one routing context's answer and replays it
# under every iBGP network id the host belongs to. Taken at face value that
# credits network B's local peer with network A's live neighbours — sessions
# that were never measured for B, which SdwanBgpSessionHealthSensor then
# senses and SdwanBgpSessionRemediateExecutor acts on.
#
# This writer is the last place that can tell the difference WITHOUT a
# rebuilt agent, and it can, because a network's iBGP neighbours are always
# peers of that network (Sdwan::Bgp::ConfigCompiler#neighbors_for only ever
# returns `peer.network.peers`) and every peer address is allocated out of
# its network's own /64. A reported neighbour outside the reporting
# network's prefix therefore does not belong to it, full stop.
#
# Three outcomes are recorded per network, on the local peer's
# `bgp_session_state["observation"]`, and they are deliberately distinct:
#
#   measured        — the poll answered for THIS network. Zero sessions here
#                     is a real zero.
#   unattributable  — sessions arrived that this network cannot own, or one
#                     unscoped poll was replayed across a host running
#                     several fabrics. Either way a wrong row could have
#                     been written, and what we did NOT measure is not
#                     reported as zero.
#   not_measured    — nothing was measured for this network and no wrong row
#                     can have been written: the agent said so outright
#                     (vtysh missing, FRR down, VRF scope unconfirmed), or
#                     an unscoped agent queried the global BGP instance on a
#                     host whose only fabric lives in a VRF — Bgp::
#                     ConfigCompiler emits NO global `router bgp` block, so
#                     that poll asked an instance that does not exist.
#
# "no report at all" stays distinct from all three: the peer's observation
# block simply ages, and the session rows go stale for the existing
# sdwan_bgp_session_stale signal.
module Sdwan
  class BgpSessionWriter
    OBSERVATION_KEY = "observation"
    # Cap the sample so one badly-behaved host cannot grow the jsonb without
    # bound; the count beside it carries the full magnitude.
    REJECTED_SAMPLE_LIMIT = 10

    def initialize(instance:, peer_by_network:, networks_payload:)
      @instance = instance
      @peer_by_network = peer_by_network
      @networks_payload = networks_payload
      @resolver_cache = {}
      @prefix_cache = {}
    end

    def write!
      written = 0
      now = Time.current

      @networks_payload.each do |np|
        net_id = value(np, :network_id)
        local_peer = @peer_by_network[net_id]
        next unless local_peer # agent reported a network this instance no longer owns

        scoped = vrf_scoped_agent?(np)

        if explicitly_not_measured?(np)
          record_observation!(local_peer, now: now, scoped: scoped,
                              status: "not_measured",
                              reason: value(np, :not_measured_reason).presence || "unspecified",
                              accepted: 0, rejected: 0, rejected_sample: [])
          next
        end

        sessions = Array(value(np, :sessions))
        attributable, foreign = sessions.partition { |s| attributable_to?(local_peer, s) }

        attributable.each do |s|
          row = upsert_session(local_peer, np, s, now)
          written += 1 if row
        end

        outcome = verdict(local_peer, scoped, attributable, foreign)
        # Retract what this peer should never have owned. Driven by the
        # VERDICT, not by the current report's rejects: once the agent is
        # rebuilt, a VRF-scoped poll simply never mentions the other
        # network's neighbours again, so a reject-driven retraction would
        # leave every row the OLD code filed frozen in place — aging past
        # STALE_WINDOW while the routing dashboard keeps serving a session
        # this network never had. Only run it when the report is good enough
        # to be authoritative; an absence is not evidence a row is wrong.
        retract_misattributed(local_peer) if outcome[:status] != "not_measured"

        record_observation!(local_peer, now: now, scoped: scoped,
                            **outcome,
                            accepted: attributable.size, rejected: foreign.size,
                            rejected_sample: foreign.filter_map { |s| neighbor_address_of(s) }
                                                    .first(REJECTED_SAMPLE_LIMIT))
      end
      written
    end

    private

    # The status/reason pair for a report that the agent did not disclaim.
    #
    # An unscoped agent on a multi-iBGP host is unattributable EVEN WHEN
    # nothing was rejected: a single global poll answers for one routing
    # context, so an empty result says nothing about this particular network.
    # Recording that as "measured, zero sessions" would be the same
    # fabrication in a quieter form — and the empty case is the LIKELY one,
    # because Bgp::ConfigCompiler#render_per_vrf_bgp_blocks emits no global
    # `router bgp` block at all, so an unscoped poll on a VRF-assigned host
    # describes an instance that does not exist.
    #
    # The multi-iBGP predicate is computed from LIVE rows, not from the
    # Sdwan::MultiIbgpHostFlagger stamp. The stamp is provenance (when the
    # host entered this shape); a stamp is also something that can be missing
    # — every host already multi-iBGP before this shipped has none — and a
    # missing stamp must not read as "single network, so that zero is real".
    def verdict(local_peer, scoped, attributable, foreign)
      if foreign.any?
        { status: "unattributable", reason: "foreign_neighbor_addresses" }
      elsif scoped
        # The agent named the VRF and FRR confirmed it answered for that VRF.
        { status: "measured", reason: nil }
      elsif host_ibgp_network_count >= 2
        # One unscoped poll, several fabrics it could have described. Even an
        # empty answer says nothing about THIS network, and a non-empty one
        # risks the misattribution this change exists to remove.
        { status: "unattributable", reason: "legacy_unscoped_agent" }
      elsif attributable.empty? && vrf_isolated?(local_peer)
        # One iBGP network, but its `router bgp` block lives in a VRF and
        # Bgp::ConfigCompiler emits NO global block, so an unscoped poll
        # queried an instance that does not exist. Nothing was measured.
        # Distinct from the multi-network arm above: no wrong row can have
        # been written here, so this is an absence, not a misattribution.
        { status: "not_measured", reason: "legacy_unscoped_agent_vrf_isolated" }
      else
        # Either the poll came back with this network's own neighbours —
        # evidence it did answer for this network — or the host has no VRF
        # assignment yet, so the global instance IS this network's instance.
        { status: "measured", reason: nil }
      end
    end

    # How many iBGP networks this host actually belongs to, right now. One
    # query per writer instance. Delegated so the writer and the flagger
    # cannot drift apart on what "multi-iBGP" means.
    def host_ibgp_network_count
      @host_ibgp_network_count ||=
        ::Sdwan::MultiIbgpHostFlagger.ibgp_network_count(node_instance_id: @instance&.id)
    end

    # Does this network's BGP live inside a VRF on this host? If so the
    # global BGP instance holds none of it.
    def vrf_isolated?(local_peer)
      return false if @instance.nil?

      key = local_peer.sdwan_network_id
      @vrf_isolated_cache ||= {}
      return @vrf_isolated_cache[key] if @vrf_isolated_cache.key?(key)

      @vrf_isolated_cache[key] = ::Sdwan::HostVrfAssignment.compilable.exists?(
        node_instance_id: @instance.id, sdwan_network_id: key
      )
    end

    # A session belongs to the reporting network when its neighbour address
    # falls inside that network's prefix, or (belt and braces, for addresses
    # allocated before the current prefix scheme) when it resolves to an
    # actual peer of that network.
    def attributable_to?(local_peer, session_payload)
      addr = neighbor_address_of(session_payload)
      return false if addr.blank?
      return true if within_network_prefix?(local_peer.sdwan_network_id, addr)

      resolve_neighbor_peer_id(local_peer.sdwan_network_id, addr).present?
    end

    def within_network_prefix?(network_id, addr)
      prefix = network_prefix(network_id)
      return false if prefix.nil?

      prefix.include?(IPAddr.new(addr))
    rescue StandardError
      # A malformed address, or one from a different family than the
      # network's prefix, is not attributable to this network.
      false
    end

    def network_prefix(network_id)
      return @prefix_cache[network_id] if @prefix_cache.key?(network_id)

      cidr = ::Sdwan::Network.where(id: network_id).pick(:cidr_64)
      @prefix_cache[network_id] =
        begin
          cidr.present? ? IPAddr.new(cidr) : nil
        rescue StandardError
          nil
        end
    end

    # Delete every row filed under this peer whose neighbour cannot belong to
    # this peer's network — the ones in the current report that were just
    # rejected, AND the ones the old unscoped code filed on earlier ticks,
    # which a VRF-scoped poll will never mention again.
    #
    # Scoped to `sdwan_peer_id`, the same key the writer creates rows under,
    # so it can only ever remove a row this code path produced. The
    # attribution test is the identical predicate that gates writes, so a row
    # this writer would accept today is never a candidate.
    #
    # LIMIT, stated: a BGP neighbour on this VRF that the platform did not
    # configure (an operator-added transit session) would fail the same test
    # and be retracted on every tick. Not reachable through the platform's
    # own config — Bgp::ConfigCompiler#neighbors_for only ever emits peers of
    # the same network — but it is the shape to revisit if eBGP lands.
    def retract_misattributed(local_peer)
      candidates = ::Sdwan::BgpSession.where(sdwan_peer_id: local_peer.id)
                                      .pluck(:id, :neighbor_address)
      doomed = candidates.filter_map do |id, addr|
        id unless attributable_to?(local_peer, { "neighbor_address" => addr })
      end
      return if doomed.empty?

      ::Sdwan::BgpSession.where(id: doomed).delete_all
    end

    def record_observation!(peer, status:, reason:, accepted:, rejected:, rejected_sample:, scoped:, now:)
      observation = {
        "status"             => status,
        "reason"             => reason,
        "observed_at"        => now.utc.iso8601,
        "sessions_accepted"  => accepted,
        "sessions_rejected"  => rejected,
        "rejected_neighbors" => rejected_sample,
        # false = the reporting agent predates VRF-scoped observation and
        # cannot tell this host's iBGP networks apart. This is the rebuild
        # boundary, recorded per report rather than guessed at.
        "agent_vrf_scoped"   => scoped
      }.compact

      # jsonb_set on the single key, not a read-modify-write of the whole
      # column: Sdwan::MultiIbgpHostFlagger writes a sibling key on the same
      # row from the enrollment path, and a whole-column write from an agent
      # tick that started before it would silently erase that key.
      #
      # update_all, not update!: Sdwan::Peer's after_save callback
      # re-materializes SubnetAdvertisement rows, and an observation stamp
      # arriving on every agent tick must not drag that behind it.
      #
      # Deliberately NOT mirrored back onto the in-memory peer: assigning
      # bgp_session_state would mark the attribute dirty, and any later
      # `save` on that object would write the whole column back — exactly
      # the read-modify-write merge_key! exists to avoid.
      ::Sdwan::MultiIbgpHostFlagger.merge_key!(peer_id: peer.id, key: OBSERVATION_KEY, value: observation)
    end

    # A payload that carries a BOOLEAN `measured` comes from an agent built
    # with VRF-scoped observation (IMP-2f34679b6b73). Its absence is the
    # legacy shape and is NOT the same as `measured: false`. A present-but-
    # null value asserts nothing at all, so it is treated as the legacy shape
    # too — otherwise the weakest possible payload would earn the strongest
    # possible claim (`measured`, `agent_vrf_scoped: true`).
    def vrf_scoped_agent?(network_payload)
      %w[true false].include?(value(network_payload, :measured).to_s)
    end

    def explicitly_not_measured?(network_payload)
      return false unless vrf_scoped_agent?(network_payload)

      raw = value(network_payload, :measured)
      raw == false || raw.to_s == "false"
    end

    def value(hash, key)
      hash[key].nil? ? hash[key.to_s] : hash[key]
    end

    def neighbor_address_of(session_payload)
      value(session_payload, :neighbor_address)
    end

    def upsert_session(local_peer, network_payload, session_payload, now)
      neighbor_address = neighbor_address_of(session_payload)
      return nil if neighbor_address.blank?

      new_state = (value(session_payload, :state) || "idle").to_s
      uptime = value(session_payload, :uptime_seconds).to_i
      rx = value(session_payload, :prefixes_received).to_i
      tx = value(session_payload, :prefixes_sent).to_i
      last_error = value(session_payload, :last_error)

      existing = ::Sdwan::BgpSession.find_by(
        sdwan_peer_id: local_peer.id,
        neighbor_address: neighbor_address
      )

      neighbor_peer_id = resolve_neighbor_peer_id(local_peer.sdwan_network_id, neighbor_address)

      attrs = {
        sdwan_peer_id: local_peer.id,
        sdwan_network_id: local_peer.sdwan_network_id,
        neighbor_peer_id: neighbor_peer_id,
        neighbor_address: neighbor_address,
        state: new_state,
        uptime_seconds: uptime,
        prefixes_received: rx,
        prefixes_sent: tx,
        last_error: last_error.presence,
        last_observed_at: now
      }

      if existing
        # State transition? Stamp last_state_change_at.
        if existing.state != new_state
          attrs[:last_state_change_at] = now
        end
        existing.update!(attrs)
        existing
      else
        attrs[:last_state_change_at] = now
        create_or_recover_session(local_peer, neighbor_address, attrs, new_state, now)
      end
    end

    # Insert the new session row, tolerating a concurrent insert. Two overlapping
    # agent ticks can both miss the find_by above and race to create! the same
    # (sdwan_peer_id, neighbor_address) row; the unique index rejects the loser
    # with RecordNotUnique. The agent retries on every tick, so a 500 here storms
    # — recover by updating the row the race winner just created.
    def create_or_recover_session(local_peer, neighbor_address, attrs, new_state, now)
      ::Sdwan::BgpSession.create!(attrs)
    rescue ActiveRecord::RecordNotUnique
      winner = ::Sdwan::BgpSession.find_by(
        sdwan_peer_id: local_peer.id, neighbor_address: neighbor_address
      )
      return nil unless winner

      update_attrs = attrs.except(:last_state_change_at)
      update_attrs[:last_state_change_at] = now if winner.state != new_state
      winner.update!(update_attrs)
      winner
    end

    # Resolve a neighbor_address (overlay /128 or /32) to a peer_id by
    # looking up another peer in the same network with that assigned_address.
    # The agent strips the mask suffix; we try both with-and-without.
    def resolve_neighbor_peer_id(network_id, neighbor_address)
      key = "#{network_id}:#{neighbor_address}"
      return @resolver_cache[key] if @resolver_cache.key?(key)

      candidates = [ neighbor_address, "#{neighbor_address}/128", "#{neighbor_address}/32" ]
      hit = ::Sdwan::Peer.where(sdwan_network_id: network_id, assigned_address: candidates).pick(:id)

      # Also try mask-stripped lookup if assigned_address comes back with /128
      hit ||= ::Sdwan::Peer.where(sdwan_network_id: network_id)
                          .find { |p| p.assigned_address.to_s.split("/").first == neighbor_address }&.id

      @resolver_cache[key] = hit
    end
  end
end
