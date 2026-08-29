# frozen_string_literal: true

module System
  module Autonomy
    # The single refusal arm for an action a reconcile gate will not permit.
    #
    # TWO DIFFERENT FAILURES WEAR THIS ONE ARM, and conflating them cost five
    # weeks of a shipped feature being silently dead.
    #
    # A gate's `permitted_actions` IS the Ai::InterventionPolicy row set for its
    # agent, so "the operator did not permit this" and "nobody ever seeded this"
    # are the same state. When the category is one the platform's own
    # DecisionEngine ROUTES signals to, the second reading is the true one: the
    # code declares a lane, the database has no policy for it, and every signal
    # on that lane is blocked while the sensor happily keeps emitting.
    #
    # Measured on live ops-hub 2026-08-24: db:seed runs only on FIRST BOOT
    # (rails-start.sh, marker-guarded), so nine policies added to seeds
    # afterwards had never reached production — including
    # system.module_verify_investigate, whose sensors had been firing into this
    # arm since the day it shipped. The only thing distinguishing it from a
    # deliberate block was a null `gate`, which nothing read, and a WARN nobody
    # greps.
    #
    # It STILL BLOCKS either way — fail-safe is right, the defect was the
    # SILENCE. A routed lane now says so at error level with a distinct gate an
    # operator can query for.
    #
    # SCOPE: this guarantees the RECONCILE gates (the gate_action! twins), not
    # every approval minted in the extension. Six sites drive core
    # Ai::AutonomyGate.evaluate directly, which mints its own approvals and
    # never passes through here; they are safe only because their action
    # categories are disjoint from DecisionEngine.routed_action_categories.
    #
    # WHY THIS IS A MIXIN AND NOT A DecisionEngine CLASS METHOD
    #
    # The routed SET belongs to DecisionEngine (and is read from it below), but
    # the REFUSAL is the gate's own contract: it returns the gate's result hash,
    # logs under the gate's own tag, and names the gate's own agent. Putting it
    # here makes adopting it a structural, observable property of a gate class —
    # `Klass.include?(RoutedLaneGuard)` — which a spec can enumerate and enforce
    # over every gate_action! implementation in the extension. A class method on
    # DecisionEngine would leave "did this gate actually call it?" invisible,
    # which is precisely how the first fix reached one of two twins.
    #
    # Mix into a reconcile gate that exposes `#agent` and `#permitted_actions`,
    # and take its whole unpermitted arm from here:
    #
    #   def gate_action!(action_category, ...)
    #     return refuse_unpermitted_action(action_category) unless
    #       permitted_actions.include?(action_category)
    #     ...
    #   end
    module RoutedLaneGuard
      # Gate value for a lane the code routes to but the database has no policy
      # row for. Distinct from "block"/"silent" (an operator's decision) and
      # from "unknown_policy" (a row carrying an unrecognised value) — this one
      # means the configuration is MISSING, which is a deploy defect, not a
      # policy.
      GATE_POLICY_MISSING = "policy_missing"

      # The complete refusal for an action outside the gate's policy row set.
      # Callers hand over the WHOLE arm rather than asking a predicate and
      # composing their own result, so a second gate cannot adopt half of it.
      def refuse_unpermitted_action(action_category)
        if routed_lane?(action_category)
          Rails.logger.error(
            "[#{autonomy_log_tag}] MISCONFIGURED LANE: '#{action_category}' is routed by " \
            "DecisionEngine but has NO intervention policy row on agent '#{agent&.name}'. " \
            "Every signal on this lane is being blocked and no operator is reached. " \
            "Re-run that agent's seed against this database."
          )
          return { decision: :blocked, gate: GATE_POLICY_MISSING, reason: GATE_POLICY_MISSING }
        end

        # A category nothing routes to is an ordinary refusal, not a deploy
        # defect. Conflating them would fire the misconfiguration alarm on every
        # stray string and train operators to ignore it.
        Rails.logger.warn(
          "[#{autonomy_log_tag}] Action '#{action_category}' not in agent '#{agent&.name}' policies — blocked"
        )
        { decision: :blocked, reason: "not_permitted" }
      end

      def routed_lane?(action_category)
        ::System::Fleet::DecisionEngine.routed_action_categories.include?(action_category)
      end

      # Log prefix, derived so a new gate inherits a correct tag without
      # declaring one: FleetAutonomyService -> "FleetAutonomy",
      # CveResponderService -> "CveResponder". Override where a class name does
      # not read well as an operator-facing tag.
      def autonomy_log_tag
        self.class.name.to_s.demodulize.sub(/Service\z/, "")
      end
    end
  end
end
