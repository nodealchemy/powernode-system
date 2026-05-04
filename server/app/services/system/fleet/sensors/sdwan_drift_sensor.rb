# frozen_string_literal: true

# Detects SDWAN peers that have drifted out of healthy handshake windows.
# A peer is "drifted" when its last_handshake_at is older than the
# DEGRADED_HANDSHAKE_WINDOW (5 min) defined on Sdwan::Peer — meaning the
# WireGuard tunnel hasn't rekeyed recently, which usually signals network
# trouble (NAT timeout, ISP flap, key mismatch).
#
# Emits one signal per drifted peer; the DecisionEngine routes them to
# the system.sdwan_peer_remediate action_category. Default policy is
# notify_and_proceed (re-issue config + restart wg interface auto-fires;
# operators get a notification).
#
# Slice 5 of the SDWAN plan (we-are-continuing-development-spicy-bear.md).
module System
  module Fleet
    module Sensors
      class SdwanDriftSensor < BaseSensor
        DRIFT_WINDOW = 5.minutes
        SEVERE_DRIFT = 30.minutes

        def sense
          return [] unless defined?(::Sdwan::Peer)

          ::Sdwan::Peer
            .joins(:network)
            .where(sdwan_networks: { account_id: account.id, status: %w[registered active] })
            .where("last_handshake_at IS NOT NULL")
            .where("last_handshake_at < ?", DRIFT_WINDOW.ago)
            .find_each.map do |peer|
              age = Time.current - peer.last_handshake_at
              signal(
                kind: "system.sdwan_peer_drift",
                severity: severity_for(age),
                payload: {
                  peer_id: peer.id,
                  network_id: peer.sdwan_network_id,
                  node_instance_id: peer.node_instance_id,
                  publicly_reachable: peer.publicly_reachable,
                  status: peer.status,
                  last_handshake_at: peer.last_handshake_at.utc.iso8601,
                  handshake_age_seconds: age.to_i,
                  remediation_action: "system.sdwan_peer_remediate"
                },
                fingerprint: "sdwan_peer_drift:#{peer.id}"
              )
            end
        end

        private

        def severity_for(age_seconds)
          return :critical if age_seconds >= SEVERE_DRIFT.to_i
          return :high     if age_seconds >= 15.minutes.to_i
          :medium
        end
      end
    end
  end
end
