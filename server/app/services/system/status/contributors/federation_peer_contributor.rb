# frozen_string_literal: true

module System
  module Status
    module Contributors
      # One component per federation peer (campaign 01a08c9b B3).
      #
      # ── SCOPE ───────────────────────────────────────────────────────────
      # `revoked` and nothing else. It is the model's one terminal state — the
      # transition table gives it no exits — and the topology builder already
      # excludes it the same way. `suspended` is NOT gone: it is a reversible
      # operator pause and reports `held`.
      #
      # ── HEARTBEAT IS ONLY A QUESTION FOR PLATFORM PEERS ─────────────────
      # #heartbeat_stale? returns false unconditionally for an sdwan_only peer,
      # which never heartbeats. Emitting the condition anyway would report
      # "fresh" for a peer that has never sent one — a constant that cannot
      # fail, dressed as an observation. It is omitted instead.
      class FederationPeerContributor < ::Platform::Status::Contributor
        include ::System::Status::ConditionHelpers

        KIND  = "federation_peer"
        MODEL = ::System::FederationPeer

        GONE_STATUSES = %w[revoked].freeze
        HEARTBEAT = "Heartbeat"
        ACCEPTANCE = "Acceptance"

        LIFECYCLE = {
          "active"    => { status: true,  reason: "Active" },
          "enrolled"  => { status: true,  reason: "Enrolled" },
          "accepted"  => { status: true,  reason: "Accepted" },
          "proposed"  => { status: true,  reason: "Proposed" },
          # Intent, carried on Held.
          "suspended" => { status: true,  reason: "Suspended" },
          "degraded"  => { status: false, reason: "Degraded" },
          # Never enumerated; mapped so a scope defect cannot read as healthy.
          "revoked"   => { status: false, reason: "Revoked",
                           severity: ::Platform::Status::Condition::SEVERITY_DOWN }
        }.freeze

        # The states where the peering is still being established. Not a fault:
        # a proposed peer is waiting on the other side to accept.
        PROGRESSING = { "proposed" => "AwaitingAcceptance", "accepted" => "AwaitingEnrolment" }.freeze

        # The two states the model's own heartbeat_stale scope watches.
        HEARTBEAT_EXPECTED = %w[enrolled active].freeze

        def kind = KIND

        def account_scoped? = true

        # FederationPeerLivenessSensor already escalates this kind
        # (system.federation_peer_liveness) and claims through
        # SignalState.claim_notification!.
        def escalates? = false

        def each_component(account)
          return if account.blank?

          MODEL.where(account_id: account.id)
               .where.not(status: GONE_STATUSES)
               .find_each { |peer| yield peer }
        end

        def ref_for(record) = record.id.to_s

        # No name column; the remote URL is what an operator recognises.
        def display_name_for(record)
          record.remote_instance_url.presence || record.id.to_s
        end

        def environment_id_for(record) = record.environment_id

        def observed_generation_for(record) = record.updated_at&.iso8601

        def presentation
          { "icon" => "Globe", "label" => "Federation peer", "group_order" => 100 }
        end

        # fc-25: /system/federation/* was deleted outright (no redirect) once
        # FederationHubPage's control surfaces merged into ServiceDeliveryPage's
        # Peers tab — that tab is the only reachable destination for a
        # federation peer record now.
        def links_for(_record)
          [ { "label" => "Federation", "path" => "/app/system/service-delivery/peers" } ]
        end

        # No node edge of any kind exists on this model — its only structural
        # parent is another federation peer, and a self-FK chain is a topology
        # this plane does not model.
        def dependencies_for(_record) = []

        def actions_for(_record) = []

        def conditions_for(record)
          now = Time.current
          [
            enum_condition(type: "Lifecycle", mapping: LIFECYCLE, value: record.status,
                           evidence: { "peer_kind" => record.peer_kind.to_s }, now: now),
            held_condition(cause: record.status.to_s == "suspended" ? "Suspended" : nil,
                           message: record.metadata.is_a?(Hash) ? record.metadata["suspension_reason"] : nil,
                           now: now),
            progressing_condition(cause: PROGRESSING[record.status.to_s], now: now),
            acceptance_condition(record, now),
            heartbeat_condition(record, now)
          ].compact
        end

        private

        # A proposed peer is waiting for the other side to accept with a token.
        # Once that token has expired, #accept! refuses it (acceptance_token_error,
        # the same rule both accept doors run), so the peering can never finish.
        # Progressing alone reported that forever (B3 review F5); this reads it
        # degraded with the expiry named. Asked only when a token was issued: a
        # peer with no digest (drill mode) accepts without one.
        def acceptance_condition(record, now)
          return nil unless record.status.to_s == "proposed"
          return nil if record.acceptance_token_digest.blank?

          expires_at = record.acceptance_token_expires_at
          expired = expires_at.present? && expires_at < now

          CONDITION.build(
            type: ACCEPTANCE, status: !expired,
            reason: expired ? "AcceptanceTokenExpired" : "AcceptanceTokenValid",
            message: expired ? "acceptance token expired at #{expires_at.iso8601}; accept! refuses it" : nil,
            evidence: { "acceptance_token_expires_at" => expires_at&.iso8601 },
            now: now
          )
        end

        def heartbeat_condition(record, now)
          return nil unless record.peer_kind.to_s == "platform"
          return nil unless HEARTBEAT_EXPECTED.include?(record.status.to_s)

          stale = record.heartbeat_stale?
          evidence = {
            "last_heartbeat_at" => record.last_heartbeat_at&.iso8601,
            "stale_after_seconds" => MODEL::HEARTBEAT_STALE_AFTER.to_i
          }

          CONDITION.build(
            type: HEARTBEAT, status: !stale,
            reason: stale ? (record.last_heartbeat_at.nil? ? "NeverHeartbeat" : "HeartbeatStale") : "HeartbeatFresh",
            evidence: evidence, now: now
          )
        end
      end
    end
  end
end
