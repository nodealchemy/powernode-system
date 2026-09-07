# frozen_string_literal: true

module System
  module Fleet
    # IMP-b8cab7f951c7 — the ONE emit path for "this lane declined to act, and
    # here is which target, which command, and why".
    #
    # WHY A SHARED MODULE. IMP-ee681c537f76 put this on DecisionEngine as a
    # private method because it had one caller. It now has six, in two classes:
    # four refusal branches in DecisionEngine and two MCP producers in
    # Ai::Tools::SystemFleetTool that never reach a decision event at all, so
    # the generic "decision events should carry remediation_applied" change
    # cannot reach them either. Extracting is what keeps that one pattern.
    #
    # NOT RELOCATED TO EventBroadcaster, deliberately and per operator ruling:
    # that seam is the generic writer and does no dedup of its own, and folding
    # a domain-specific throttle into it was rejected as over-merge. This module
    # sits above it and calls it.
    #
    # WHY IT NEEDS A THROTTLE AT ALL. A refusal is a PERSISTENT condition — the
    # node stays dead, the plane stays foreign, the budget stays exceeded —
    # while the signal that triggers it re-fires on the engine's decide cadence.
    # EventBroadcaster unconditionally create!s and never reads correlation_id
    # for suppression, so undeduped this is the ~144-rows-a-day storm shape that
    # escalate_blocked_adaptation! already had to fix once.
    module DispatchRefusalReporter
      # THE CLOSED VOCABULARY. Without this the classes are free-form symbols
      # invented at each call site, and an operator querying the ledger has no
      # way to know the set is closed or what to filter on. Two families:
      #
      #   LIVENESS  — a property of the target's AGENT, derived from
      #               NodeInstance#silence_verdict by #liveness_refusal_class.
      #   DECISION  — a property of the DECISION, not the target: the plane does
      #               not own it, it is our own host, the plan is too big, or a
      #               task is already open.
      LIVENESS_REFUSAL_CLASSES = %i[offline went_silent never_reported].freeze
      DECISION_REFUSAL_CLASSES =
        %i[foreign_control_plane self_managed disruption_budget task_in_flight].freeze
      REFUSAL_CLASSES = (LIVENESS_REFUSAL_CLASSES + DECISION_REFUSAL_CLASSES).freeze

      # :offline (outside the live replica set) | :went_silent | :never_reported
      #
      # Lives HERE rather than on either caller because both need it — the
      # engine's dead-target fence and the tool's retemplate loop — and an
      # inlined second copy is how the vocabulary starts to drift.
      # #silence_verdict is stable across a cloud-sync flap within a class,
      # which is what makes it usable as a dedup key at all.
      def liveness_refusal_class(instance)
        instance.silence_verdict || :offline
      end

      # One event per account+instance+command+CLASS per window, not per tick.
      DISPATCH_REFUSED_ALARM_TTL_SECONDS =
        (ENV["FLEET_DISPATCH_REFUSED_TTL_SECONDS"].presence&.to_i&.positive? || 60 * 60)

      # THE CLASS IS IN THE KEY, and both of the obvious alternatives are wrong
      # in opposite directions — this was an earlier review's finding and is
      # restated here because the key is the whole design.
      #
      # Keying on the reason STRING re-announces on every hourly cloud-sync flap
      # (running -> error -> running writes a new reason for an unchanged
      # condition). Keying on instance+command ALONE is worse the other way: a
      # target refused as `terminated` at 10:00 and, at 10:10, refused as
      # `agent went silent` — a genuinely different diagnosis reached through a
      # different signal that legitimately passed the engine's own fingerprint
      # dedup — would be suppressed, and the operator would act on the stale
      # reason. The class is stable across a flap and distinct across diagnoses.
      #
      # `instance` is OPTIONAL, and only ONE of the six callers can pass nil:
      # the disruption-budget refusal, whose signal payload may name a target
      # that does not resolve. A refusal with no nameable target is still worth
      # a row — it is the only evidence the lane declined — but the row is
      # WEAKER, and saying so is the point of this paragraph: instance_id,
      # node_id, instance_status, last_heartbeat_at and correlation_id are all
      # nil, and the key degrades to account+command+class, so every
      # unresolvable-target budget refusal in an account shares one hourly slot
      # per command. That is not "the right granularity for a condition that is
      # not about one instance" — the budget refusal IS about a target, it just
      # failed to find one. It is an accepted floor, not a design.
      # `source` is the PRODUCER, supplied by the caller rather than hardcoded
      # here: this module is shared by the autonomous engine and an MCP tool,
      # and an operator reading the ledger needs to know which one declined.
      # DecisionEngine keeps the string it has emitted since IMP-ee681c537f76
      # ("decision_engine.dispatch_refused") — collapsing it into a module-wide
      # constant would have silently rewritten an operator-facing field on
      # rows that already exist.
      def emit_dispatch_refused!(account:, command:, reason:, refusal_class:, source:, instance: nil)
        # Fail LOUD on an unlisted class rather than writing a row nobody can
        # query for. The vocabulary is small and closed on purpose; an eighth
        # class is a decision, not a typo.
        unless REFUSAL_CLASSES.include?(refusal_class.to_sym)
          raise ArgumentError,
                "unknown dispatch refusal class #{refusal_class.inspect} — " \
                "add it to DispatchRefusalReporter::REFUSAL_CLASSES deliberately"
        end

        return unless claim_dispatch_refused_alarm!(account, instance, command, refusal_class)

        ::System::Fleet::EventBroadcaster.emit!(
          account: account,
          kind: "fleet.dispatch_refused",
          severity: :high,
          payload: {
            "instance_id" => instance&.id,
            "node_id" => instance&.node_id,
            "command" => command,
            "instance_status" => instance&.status,
            "refusal_class" => refusal_class.to_s,
            # NOT compacted. nil here is the DIAGNOSIS for the :never_reported
            # class — an instance the control plane marked running from provider
            # state alone — so dropping the key would delete the field an
            # operator uses to tell "never reported" from "went silent", in
            # exactly the class where it matters most.
            "last_heartbeat_at" => instance&.last_heartbeat_at&.iso8601,
            "reason" => reason
          },
          source: source,
          correlation_id: instance&.id
        )
      rescue StandardError => e
        # A missing fleet_events table is a deploy defect, not an observability
        # hiccup, and System::DeployDefect exists so it reads as a FAILED tick
        # rather than a healthy one. EventBroadcaster re-raises those
        # deliberately; swallowing them here would restore the silence this
        # module was written to break.
        #
        # DELIBERATELY STRICTER than escalate_blocked_adaptation!, whose rescue
        # this throttle is otherwise modelled on: that one swallows a schema
        # error too. This preserves what refuse_dead_target! already did rather
        # than regressing to the older sibling's behaviour.
        raise if ::System::DeployDefect.schema?(e)

        # An unlisted refusal class is a PROGRAMMING error in the call, not an
        # observability hiccup — swallowing it would leave a new call site
        # silently emitting nothing, which is the failure this whole module
        # exists to end. It has to jump the rescue explicitly, because the
        # rescue wraps the validation.
        raise if e.is_a?(ArgumentError)

        # Anything else: observability must never break the refusal it observes.
        # The work is already not being dispatched; losing the event costs
        # visibility, and raising would cost the fence.
        Rails.logger.warn("[DispatchRefusalReporter] emit failed: #{e.message}")
        nil
      end

      private

      def claim_dispatch_refused_alarm!(account, instance, command, klass)
        return true unless Rails.cache.respond_to?(:write)

        key = "fleet:dispatch_refused:#{account.id}:#{instance&.id || 'no-instance'}:#{command}:#{klass}"
        # unless_exist is the ATOMIC form. exist?-then-write races two engine
        # ticks into both claiming; harmless here (two rows instead of one) but
        # free to close.
        Rails.cache.write(key, Time.current.to_i.to_s,
                          expires_in: DISPATCH_REFUSED_ALARM_TTL_SECONDS, unless_exist: true)
      rescue StandardError => e
        Rails.logger.warn("[DispatchRefusalReporter] dedup unavailable, suppressing: #{e.message}")
        false
      end
    end
  end
end
