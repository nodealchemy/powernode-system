# frozen_string_literal: true

module System
  module Status
    # THE FLEET'S SIGNAL SOURCE for the component status plane (design §4.3,
    # the `remediation` jsonb), registered into Platform::Status::SignalSources
    # by RemediationWiring. Core pulls; this answers with plain facts.
    #
    # ── WHERE A STANDING SIGNAL IS READ FROM ────────────────────────────────
    # The FleetEvent the DecisionEngine writes for EVERY signal it receives
    # (EventBroadcaster.emit_signal!, before any routing), not SignalState: a
    # SignalState row is written only on the SECOND sighting (a dedupe), so
    # reading it would hide every signal in its first decide window.
    #
    # A signal is STANDING while it has been seen within SignalState's episode
    # window ("absence longer than this starts a NEW episode") — the setting
    # the dedupe lane already uses, so the two agree on when a condition has
    # cleared.
    #
    # ── WHICH COMPONENT A SIGNAL IS ABOUT ───────────────────────────────────
    # The fingerprint. Sensors key it on the resource they observed
    # ("boot_image_drift:<instance id>", "cert_expiring:<cert id>"), so a
    # colon-delimited segment equal to the component's ref is the sensor's own
    # statement of what the signal is about. The event's resource COLUMNS are
    # not used: an instance's event also carries its node_id, and matching on
    # it would paint every instance's remediation onto its node.
    #
    # Only UUID refs are matched. A platform_subsystem ref is a name ("redis"),
    # and a bare word could equal an arbitrary fingerprint token.
    class FleetSignalSource
      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      # RemediationOutcome's settled statuses in the fact's vocabulary.
      # pending and inconclusive say nothing about success, so they map to nil.
      SETTLED = { "effective" => "succeeded", "ineffective" => "failed" }.freeze

      # A bound on the rows read per component, not a policy value.
      EVENT_SCAN_LIMIT = 500

      def call(component_status)
        account = component_status.account
        ref = component_status.component_ref.to_s
        return [] if account.nil? || !ref.match?(UUID)

        latest_by_fingerprint(account, ref).map do |fingerprint, kind|
          {
            signal_kind: kind,
            fingerprint: fingerprint,
            approval_request_id: pending_approval_id(account, fingerprint),
            last_outcome: last_outcome(account, fingerprint),
            stuck: stuck?(account, fingerprint)
          }
        end
      end

      private

      # {fingerprint => signal_kind}, newest sighting wins. The ref is a
      # validated UUID, so it carries no regex metacharacter into the pattern.
      def latest_by_fingerprint(account, ref)
        window = ::System::Fleet::SignalState.setting("episode_reset_seconds").seconds
        ::System::FleetEvent
          .where(account_id: account.id, kind: ::System::Fleet::DecisionEngine::SIGNAL_BINDINGS.keys)
          .where(emitted_at: window.ago..)
          .where("payload->>'fingerprint' ~ ?", "(^|:)#{ref}(:|$)")
          .order(emitted_at: :desc)
          .limit(EVENT_SCAN_LIMIT)
          .pluck(Arel.sql("payload->>'fingerprint'"), :kind)
          .each_with_object({}) { |(fingerprint, kind), out| out[fingerprint] ||= kind }
      end

      # The approval the fleet gate minted for this fingerprint, read with the
      # same scope the gate's own dedup reads (FleetAutonomyService
      # #pending_fleet_approvals: pending, this account, the fleet's source).
      def pending_approval_id(account, fingerprint)
        ::Ai::ApprovalRequest.pending
          .where(account_id: account.id, source_type: ::System::Fleet::FleetAutonomyService::SOURCE_TYPE)
          .where("request_data->'payload'->>'signal_fingerprint' = ?", fingerprint)
          .order(created_at: :desc)
          .pick(:id)
      end

      def last_outcome(account, fingerprint)
        status = ::System::Fleet::RemediationOutcome
          .where(account_id: account.id, fingerprint: fingerprint, status: SETTLED.keys)
          .order(Arel.sql("validated_at DESC NULLS LAST, acted_at DESC"))
          .pick(:status)
        SETTLED[status]
      end

      # The DecisionEngine's own two triggers for escalate_stuck_remediation!:
      # a streak of ineffective outcomes at the threshold, or a remediation
      # that declared it could not converge.
      def stuck?(account, fingerprint)
        outcomes = ::System::Fleet::RemediationOutcome
        outcomes.ineffective_streak(account: account, fingerprint: fingerprint) >=
          ::System::Fleet::DecisionEngine::STUCK_STREAK_THRESHOLD ||
          outcomes.deferred_convergence?(account: account, fingerprint: fingerprint)
      end
    end
  end
end
