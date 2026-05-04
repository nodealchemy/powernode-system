# frozen_string_literal: true

# Detects iBGP sessions that have been stuck in a non-established state
# for too long. A session in "active" or "connect" briefly is normal —
# FRR's TCP state machine is climbing toward "established". Lingering
# there for more than UNHEALTHY_WINDOW means real trouble: misconfigured
# AS, mTU mismatch on the WireGuard tunnel, or peer agent down.
#
# Also flags sessions that haven't been observed in STALE_WINDOW (5 min),
# which usually means the agent reporter is silent (FRR hung, vtysh
# missing, agent crashed) — distinct from a session that IS reporting
# but isn't established.
#
# Emits one signal per unhealthy session; the DecisionEngine routes them
# to system.sdwan_bgp_session_remediate (default policy notify_and_proceed —
# the executor restarts FRR via systemctl, low blast radius).
#
# Slice 9f of the SDWAN plan.
module System
  module Fleet
    module Sensors
      class SdwanBgpSessionHealthSensor < BaseSensor
        UNHEALTHY_WINDOW = 5.minutes
        STALE_WINDOW     = 5.minutes
        SEVERE_DOWN      = 30.minutes

        def sense
          return [] unless defined?(::Sdwan::BgpSession)

          signals = []
          signals.concat(unhealthy_state_signals)
          signals.concat(stale_observation_signals)
          signals
        end

        private

        # Sessions reporting a non-established state for too long.
        def unhealthy_state_signals
          ::Sdwan::BgpSession
            .joins(:network)
            .where(sdwan_networks: { account_id: account.id })
            .where.not(state: "established")
            .where("last_state_change_at < ?", UNHEALTHY_WINDOW.ago)
            .where("last_observed_at >= ?", STALE_WINDOW.ago) # exclude stale; covered separately
            .find_each.map do |session|
              age = Time.current - session.last_state_change_at
              signal(
                kind: "system.sdwan_bgp_session_unhealthy",
                severity: severity_for(age),
                payload: {
                  bgp_session_id: session.id,
                  peer_id: session.sdwan_peer_id,
                  network_id: session.sdwan_network_id,
                  neighbor_peer_id: session.neighbor_peer_id,
                  neighbor_address: session.neighbor_address,
                  state: session.state,
                  stuck_for_seconds: age.to_i,
                  last_error: session.last_error,
                  remediation_action: "system.sdwan_bgp_session_remediate"
                },
                # Dedup on (local_peer, neighbor) — same flap re-emits
                # the same fingerprint so FleetAutonomyService squelches
                # duplicates within the dedup TTL window.
                fingerprint: "sdwan_bgp_session_unhealthy:#{session.sdwan_peer_id}:#{session.neighbor_address}"
              )
            end
        end

        # Sessions that haven't been observed at all recently. Distinct
        # signal — different remediation (restart agent? check FRR is
        # installed?) than "session reporting but down."
        def stale_observation_signals
          ::Sdwan::BgpSession
            .joins(:network)
            .where(sdwan_networks: { account_id: account.id })
            .where("last_observed_at < ?", STALE_WINDOW.ago)
            .find_each.map do |session|
              age = Time.current - session.last_observed_at
              signal(
                kind: "system.sdwan_bgp_session_stale",
                severity: :medium,
                payload: {
                  bgp_session_id: session.id,
                  peer_id: session.sdwan_peer_id,
                  network_id: session.sdwan_network_id,
                  neighbor_address: session.neighbor_address,
                  last_observed_at: session.last_observed_at.utc.iso8601,
                  stale_for_seconds: age.to_i,
                  recommended_action: "verify_agent_reporting"
                },
                fingerprint: "sdwan_bgp_session_stale:#{session.sdwan_peer_id}:#{session.neighbor_address}"
              )
            end
        end

        def severity_for(age_seconds)
          return :critical if age_seconds >= SEVERE_DOWN.to_i
          return :high     if age_seconds >= 15.minutes.to_i
          :medium
        end
      end
    end
  end
end
