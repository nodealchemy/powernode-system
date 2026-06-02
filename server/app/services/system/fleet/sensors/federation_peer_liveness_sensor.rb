# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Phase 3c — federation liveness sensor.
      #
      # Watches platform-kind System::FederationPeer rows for two classes of
      # liveness failure and emits a single signal kind the DecisionEngine
      # routes to FederationPeerRemediateExecutor:
      #
      #   1. Stale heartbeat — an enrolled/active platform peer whose
      #      last_heartbeat_at is older than HEARTBEAT_STALE_AFTER (5 min).
      #      Sourced from System::FederationPeer.heartbeat_stale (the same
      #      scope HeartbeatSweepService uses), so the sensor and the sweep
      #      agree on what "stale" means.
      #
      #   2. Cert expiring / expired — a peer whose bound federation
      #      node_certificate is past (or near) not_after. Queried directly
      #      off System::FederationPeer (mirroring CertExpirySensor) using
      #      CERT_WARN_WINDOW — the same 30-day threshold
      #      Sdwan::FederationGovernance applies — instead of running the
      #      whole account-wide governance battery every tick.
      #
      # Both flavors carry the same signal kind ("system.federation_peer_liveness")
      # — the DecisionEngine binds the kind to one remediation executor that
      # branches on payload.reason (heartbeat_stale vs cert_expiring vs
      # cert_expired). Severity tracks the underlying condition:
      #
      #   - cert_expired                    → :high
      #   - heartbeat_stale (active peer)   → :high  (was carrying live traffic)
      #   - heartbeat_stale (enrolled peer) → :medium (never fully came up)
      #   - cert_expiring                   → :medium (advisory; lead time remains)
      #
      # The sensor is pure read-side per the BaseSensor contract: it senses
      # and emits Signals, it NEVER mutates the database. The degrade /
      # re-handshake / alert side-effects live in the remediation executor
      # the DecisionEngine routes to.
      #
      # Plan reference: Decentralized Federation §C + P3.5/P3.6 (heartbeat +
      # platform-peer health) — surfaced into the fleet sensor pipeline.
      class FederationPeerLivenessSensor < BaseSensor
        SIGNAL_KIND = "system.federation_peer_liveness"

        # Cert-expiry warning lead time. Matches
        # Sdwan::FederationGovernance::CERT_EXPIRY_WARN_DAYS (30 days) so the
        # direct query here and the governance scan agree on "expiring".
        CERT_WARN_WINDOW = ::Sdwan::FederationGovernance::CERT_EXPIRY_WARN_DAYS.days

        def sense
          return [] unless defined?(::System::FederationPeer)

          heartbeat_signals + cert_signals
        end

        private

        # ── Stale heartbeat (enrolled/active platform peers) ─────────────
        # Reuses the model scope so "stale" stays defined in exactly one
        # place. enrolled peers that never heartbeated and active peers
        # that went quiet are both swept up; severity distinguishes them.
        def heartbeat_signals
          ::System::FederationPeer
            .heartbeat_stale
            .where(account_id: account.id)
            .find_each.map do |peer|
              last_hb = peer.last_heartbeat_at
              signal(
                kind: SIGNAL_KIND,
                severity: peer.status == "active" ? :high : :medium,
                payload: {
                  federation_peer_id: peer.id,
                  reason: "heartbeat_stale",
                  peer_status: peer.status,
                  remote_instance_url: peer.remote_instance_url,
                  last_heartbeat_at: last_hb&.utc&.iso8601,
                  stale_after_seconds: ::System::FederationPeer::HEARTBEAT_STALE_AFTER.to_i,
                  remediation_action: "system.federation_peer_remediate"
                },
                # Bucket by the staleness window so a peer that flaps in and
                # out of staleness re-emits at most once per window rather
                # than every 60s tick (the engine's TTL dedup then collapses
                # repeats further).
                fingerprint: "federation_peer_liveness:heartbeat_stale:#{peer.id}:#{stale_bucket(last_hb)}"
              )
            end
        end

        # ── Cert expiring / expired (direct query) ──────────────────────
        # Query peers with a bound node_certificate near (or past) not_after
        # directly — mirroring CertExpirySensor's direct-query pattern —
        # rather than running the full account-wide FederationGovernance.scan
        # battery (prefix overlap, schema drift, residency, migration chains)
        # every 60s tick just to lift out the two cert findings. The cert
        # window (CERT_WARN_WINDOW) matches FederationGovernance's
        # CERT_EXPIRY_WARN_DAYS so the two paths agree on "expiring". The
        # emitted signal kind/payload/fingerprint are identical to before.
        # Wrapped defensively: a query failure must not take the whole sensor
        # down (heartbeat signals in the same tick still run).
        def cert_signals
          warn_at = Time.current + CERT_WARN_WINDOW

          ::System::FederationPeer
            .where(account_id: account.id)
            .where.not(outbound_certificate_id: nil)
            .joins(:outbound_certificate)
            .where(system_node_certificates: { not_after: ..warn_at })
            .includes(:outbound_certificate)
            .find_each
            .filter_map { |peer| cert_signal_for(peer) }
        rescue StandardError => e
          Rails.logger.warn("[FederationPeerLivenessSensor] cert query failed: #{e.class}: #{e.message}")
          []
        end

        def cert_signal_for(peer)
          cert = peer.outbound_certificate
          return nil unless cert&.not_after

          expired = cert.not_after <= Time.current
          reason  = expired ? "cert_expired" : "cert_expiring"

          signal(
            kind: SIGNAL_KIND,
            severity: expired ? :high : :medium,
            payload: {
              federation_peer_id: peer.id,
              reason: reason,
              peer_status: peer.status,
              remote_instance_url: peer.remote_instance_url,
              governance_message: cert_message(reason, cert),
              remediation_action: "system.federation_peer_remediate"
            },
            fingerprint: "federation_peer_liveness:#{reason}:#{peer.id}"
          )
        end

        # Mirror FederationGovernance's cert-finding message text so the
        # governance_message payload reads identically on both paths.
        def cert_message(reason, cert)
          not_after = cert.not_after.utc.iso8601
          if reason == "cert_expired"
            days = ((Time.current - cert.not_after) / 1.day).to_i
            "Peer's federation cert expired #{days} day(s) ago (#{not_after}). Rotate immediately."
          else
            days = ((cert.not_after - Time.current) / 1.day).to_i
            "Peer's federation cert expires in #{days} day(s) (#{not_after}). Plan rotation."
          end
        end

        # Integer index of which HEARTBEAT_STALE_AFTER-wide bucket the last
        # heartbeat falls into. nil heartbeat (never beat) collapses to a
        # single stable "never" bucket so it doesn't churn the fingerprint.
        def stale_bucket(last_heartbeat_at)
          return "never" if last_heartbeat_at.nil?

          window = ::System::FederationPeer::HEARTBEAT_STALE_AFTER.to_i
          window = 1 if window <= 0
          (last_heartbeat_at.to_i / window)
        end
      end
    end
  end
end
