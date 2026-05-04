# frozen_string_literal: true

# Detects SDWAN networks whose hub peers are unreachable. A hub is
# "unreachable" when no peer in its network has reported a handshake
# within REACHABILITY_WINDOW — meaning either the hub itself is offline
# OR every spoke in the network has lost connectivity (which is
# operationally indistinguishable until a second hub is added).
#
# This is a network-level signal (one per network), not a peer-level one,
# because the remediation is "promote a backup hub" rather than "restart
# this peer's tunnel" — different action category, different operator
# review surface.
#
# Emits → system.sdwan_failover (default require_approval — promoting a
# hub changes the network's reachability story; operators want eyes).
#
# Slice 5 of the SDWAN plan.
module System
  module Fleet
    module Sensors
      class SdwanReachabilitySensor < BaseSensor
        REACHABILITY_WINDOW = 10.minutes

        def sense
          return [] unless defined?(::Sdwan::Network)

          ::Sdwan::Network
            .where(account_id: account.id, status: "active")
            .find_each.filter_map do |network|
              hubs = network.peers.where(publicly_reachable: true)
              next if hubs.empty?  # no hub: separate concern (compiler will warn)

              # If ANY peer in the network has a recent handshake, the network
              # is functionally up — it doesn't matter which hub is alive.
              recent = network.peers.where("last_handshake_at >= ?", REACHABILITY_WINDOW.ago).exists?
              next if recent

              # No recent handshake from any peer + at least one hub configured
              # = unreachable. Emit one signal per network.
              signal(
                kind: "system.sdwan_hub_unreachable",
                severity: severity_for(network),
                payload: {
                  network_id: network.id,
                  network_name: network.name,
                  hub_count: hubs.size,
                  spoke_count: network.peers.where(publicly_reachable: false).count,
                  last_handshake_at: network.peers.maximum(:last_handshake_at)&.utc&.iso8601,
                  remediation_action: "system.sdwan_failover"
                },
                fingerprint: "sdwan_hub_unreachable:#{network.id}"
              )
            end
        end

        private

        def severity_for(network)
          # Networks with a backup hub available can self-heal via failover;
          # networks with one hub are operationally critical.
          hub_count = network.peers.where(publicly_reachable: true).count
          return :critical if hub_count <= 1
          :high
        end
      end
    end
  end
end
