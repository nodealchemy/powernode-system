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
module Sdwan
  class BgpSessionWriter
    def initialize(instance:, peer_by_network:, networks_payload:)
      @instance = instance
      @peer_by_network = peer_by_network
      @networks_payload = networks_payload
      @resolver_cache = {}
    end

    def write!
      written = 0
      now = Time.current

      @networks_payload.each do |np|
        net_id = np[:network_id] || np["network_id"]
        local_peer = @peer_by_network[net_id]
        next unless local_peer # agent reported a network this instance no longer owns

        sessions = Array(np[:sessions] || np["sessions"])
        sessions.each do |s|
          row = upsert_session(local_peer, np, s, now)
          written += 1 if row
        end
      end
      written
    end

    private

    def upsert_session(local_peer, network_payload, session_payload, now)
      neighbor_address = session_payload[:neighbor_address] || session_payload["neighbor_address"]
      return nil if neighbor_address.blank?

      new_state = (session_payload[:state] || session_payload["state"] || "idle").to_s
      uptime = (session_payload[:uptime_seconds] || session_payload["uptime_seconds"] || 0).to_i
      rx = (session_payload[:prefixes_received] || session_payload["prefixes_received"] || 0).to_i
      tx = (session_payload[:prefixes_sent] || session_payload["prefixes_sent"] || 0).to_i
      last_error = session_payload[:last_error] || session_payload["last_error"]

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
        ::Sdwan::BgpSession.create!(attrs)
      end
    end

    # Resolve a neighbor_address (overlay /128 or /32) to a peer_id by
    # looking up another peer in the same network with that assigned_address.
    # The agent strips the mask suffix; we try both with-and-without.
    def resolve_neighbor_peer_id(network_id, neighbor_address)
      key = "#{network_id}:#{neighbor_address}"
      return @resolver_cache[key] if @resolver_cache.key?(key)

      candidates = [neighbor_address, "#{neighbor_address}/128", "#{neighbor_address}/32"]
      hit = ::Sdwan::Peer.where(sdwan_network_id: network_id, assigned_address: candidates).pick(:id)

      # Also try mask-stripped lookup if assigned_address comes back with /128
      hit ||= ::Sdwan::Peer.where(sdwan_network_id: network_id)
                          .find { |p| p.assigned_address.to_s.split("/").first == neighbor_address }&.id

      @resolver_cache[key] = hit
    end
  end
end
