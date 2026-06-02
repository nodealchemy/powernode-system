# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Phase 3c — federation peer liveness remediation.
      #
      # Invoked by the DecisionEngine when a FederationPeerLivenessSensor
      # signal (kind "system.federation_peer_liveness") proceeds through the
      # `system.federation_peer_remediate` gate. The sensor flags three
      # liveness failures; this executor branches on payload `reason` and
      # takes the matching REAL remediation action:
      #
      #   reason="heartbeat_stale"
      #     Re-handshake: probe the peer's federation_api over mTLS via
      #     Federation::PeerClient#fetch_catalog. The probe is the handshake —
      #     a reachable peer's inbound heartbeats will have already landed
      #     (record_heartbeat! lifts degraded → active). So:
      #       - probe succeeds → "rehandshaked": the peer is reachable again;
      #         reload and report its (possibly self-recovered) status. If it
      #         hasn't self-recovered but is reachable, leave it for the next
      #         inbound heartbeat (we never forge a heartbeat we didn't get).
      #       - probe fails + peer is `active` → "degraded": transition
      #         active → degraded via mark_degraded! (mirrors HeartbeatSweepService,
      #         but driven by a positive unreachability signal rather than a
      #         timer). enrolled peers can't degrade (V1_TRANSITIONS), so they
      #         fall through to "alerted".
      #       - probe fails + peer not degradable → "alerted".
      #
      #   reason="cert_expiring" / "cert_expired"
      #     Federation node-cert rotation is operator-driven for v1 (a peer
      #     cert rotation requires a cross-CA handshake with the remote
      #     operator — see FederationManagerExecutor's cert_rotation_candidates
      #     note). So we "alert": emit a high/medium FleetEvent that surfaces
      #     the rotation need in the operator dashboard. We do NOT silently
      #     rotate a federation trust cert.
      #
      # Every branch emits a FleetEvent (the durable + live alert) and returns
      # a structured result. The executor is synchronous and idempotent:
      # re-running on an already-degraded peer is a no-op degrade (mark_degraded!
      # returns false when the transition isn't allowed) and re-running the
      # probe is side-effect-free on our side.
      #
      # Reuse: Federation::PeerClient (mTLS outbound), FederationPeer state
      # machine (mark_degraded! / record_heartbeat!), EventBroadcaster.
      class FederationPeerRemediateExecutor < BaseSkillExecutor
        REASONS = %w[heartbeat_stale cert_expiring cert_expired].freeze

        skill_descriptor(
          name: "federation_peer_remediate",
          description: "Remediate a stale or cert-expiring federation peer: re-handshake a stale peer over mTLS (recovering it if reachable), degrade an unreachable active peer, or alert the operator that a federation cert needs an operator-driven rotation. Invoked by the fleet DecisionEngine off the FederationPeerLivenessSensor.",
          category: "federation",
          requires_approval: false,
          invocation_mode: "one_shot",
          blast_radius: :medium,
          inputs: {
            federation_peer_id: { type: "string", required: true,
                                  description: "System::FederationPeer to remediate" },
            reason: { type: "string", required: false,
                      description: "Liveness failure class from the sensor: heartbeat_stale | cert_expiring | cert_expired. Defaults to heartbeat_stale." },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan-only mode — report the action that would be taken without probing, degrading, or alerting" }
          },
          outputs: {
            remediated: :boolean,
            action: :string,
            reason: :string,
            federation_peer_id: :string,
            peer_status: :string,
            reachable: :boolean,
            detail: :string
          }
        )

        binds_to "SDWAN Manager"

        protected

        def perform(federation_peer_id:, reason: "heartbeat_stale", dry_run: false, **_extra)
          reason = reason.to_s.presence || "heartbeat_stale"
          unless REASONS.include?(reason)
            return failure("reason must be one of: #{REASONS.join(', ')}")
          end

          peer = ::System::FederationPeer.find_by(id: federation_peer_id, account_id: @account.id)
          return failure("federation peer not found in account scope") unless peer

          unless peer.platform_peer?
            return failure("federation peer #{peer.id} is peer_kind=#{peer.peer_kind}; liveness remediation only applies to platform peers")
          end

          if dry_run
            return success(
              remediated: false,
              dry_run: true,
              action: planned_action(reason, peer),
              reason: reason,
              federation_peer_id: peer.id,
              peer_status: peer.status
            )
          end

          case reason
          when "heartbeat_stale"
            remediate_heartbeat_stale(peer)
          when "cert_expiring", "cert_expired"
            remediate_cert(peer, reason)
          end
        end

        private

        # ── Heartbeat-stale: probe → recover | degrade | alert ───────────
        def remediate_heartbeat_stale(peer)
          probe = probe_peer(peer)

          if probe[:reachable]
            # The probe is our re-handshake. A reachable peer's inbound
            # heartbeats record_heartbeat! it back to active on their own;
            # reload to report whatever state that produced. We never forge
            # a heartbeat we didn't receive.
            peer.reload
            emit_event!(peer, kind: "federation.peer.rehandshaked", severity: :medium,
                              detail: "peer reachable over federation_api; awaiting inbound heartbeat recovery")
            return success(
              remediated: true,
              action: "rehandshaked",
              reason: "heartbeat_stale",
              federation_peer_id: peer.id,
              peer_status: peer.status,
              reachable: true,
              detail: "Re-handshake probe succeeded; peer is reachable. Status=#{peer.status}."
            )
          end

          # Unreachable. Degrade an active peer (positive unreachability
          # signal). mark_degraded! is gated by V1_TRANSITIONS — only
          # `active` can degrade; enrolled/already-degraded return false.
          # The active → degraded transition fires
          # FederationPeer#broadcast_peer_state! ("federation.peer.degraded"),
          # which is the single canonical state-change event — so we thread
          # the probe error into its reason rather than re-emitting a duplicate.
          if peer.status == "active" &&
             peer.mark_degraded!(reason: "liveness remediation: peer unreachable over federation_api (#{probe[:error]})")
            return success(
              remediated: true,
              action: "degraded",
              reason: "heartbeat_stale",
              federation_peer_id: peer.id,
              peer_status: peer.status,
              reachable: false,
              detail: "Peer unreachable (#{probe[:error]}); transitioned active → degraded."
            )
          end

          # Not degradable (enrolled-never-came-up, or already degraded) —
          # alert only. Repeated unreachability past the dedup TTL re-queues,
          # which is the correct escalation toward operator suspension.
          emit_event!(peer, kind: "federation.peer.unreachable", severity: :high,
                            detail: probe[:error])
          success(
            remediated: false,
            action: "alerted",
            reason: "heartbeat_stale",
            federation_peer_id: peer.id,
            peer_status: peer.status,
            reachable: false,
            detail: "Peer unreachable (#{probe[:error]}) and not in a degradable state (status=#{peer.status}); alerted operator."
          )
        end

        # ── Cert expiring/expired: alert (operator-driven rotation) ──────
        # Rotating a federation trust cert requires a cross-CA handshake with
        # the remote operator; v1 does not auto-rotate. We surface the need.
        def remediate_cert(peer, reason)
          severity = reason == "cert_expired" ? :high : :medium
          cert = peer.outbound_certificate
          detail =
            if cert&.not_after
              "Federation cert (id=#{cert.id}) not_after=#{cert.not_after.utc.iso8601}. " \
              "Operator-driven rotation required (cross-CA handshake with the remote operator)."
            else
              "Federation cert flagged #{reason} but no bound outbound_certificate found; verify peer cert binding."
            end

          emit_event!(peer, kind: "federation.peer.cert_rotation_required",
                            severity: severity, detail: detail,
                            extra: { certificate_id: cert&.id, cert_reason: reason })

          success(
            remediated: false,
            action: "alerted",
            reason: reason,
            federation_peer_id: peer.id,
            peer_status: peer.status,
            reachable: nil,
            requires_operator_action: true,
            certificate_id: cert&.id,
            detail: detail
          )
        end

        # Probe the peer's federation_api over mTLS. fetch_catalog is a safe
        # read (no side-effects on the remote) and exercises the full mTLS
        # path, so a 2xx means the trust relationship + connectivity are
        # healthy. Any PeerClient error (connection/HTTP/client) → unreachable.
        def probe_peer(peer)
          client = ::Federation::PeerClient.new(peer: peer)
          client.fetch_catalog
          { reachable: true, error: nil }
        rescue ::Federation::PeerClient::ClientError => e
          { reachable: false, error: "#{e.class.name.demodulize}: #{e.message}" }
        rescue StandardError => e
          { reachable: false, error: "#{e.class}: #{e.message}" }
        end

        def planned_action(reason, peer)
          case reason
          when "heartbeat_stale"
            peer.status == "active" ? "probe; degrade if unreachable" : "probe; alert if unreachable"
          else
            "alert operator (cert rotation is operator-driven)"
          end
        end

        def emit_event!(peer, kind:, severity:, detail:, extra: {})
          return unless defined?(::System::Fleet::EventBroadcaster)

          ::System::Fleet::EventBroadcaster.emit!(
            account: @account,
            kind: kind,
            severity: severity,
            source: "federation_peer_remediate_executor",
            payload: {
              federation_peer_id: peer.id,
              peer_status: peer.status,
              remote_instance_url: peer.remote_instance_url,
              detail: detail
            }.merge(extra.compact)
          )
        rescue StandardError => e
          Rails.logger.warn("[FederationPeerRemediateExecutor] event emit failed: #{e.message}")
        end
      end
    end
  end
end
