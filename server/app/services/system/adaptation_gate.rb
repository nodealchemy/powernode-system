# frozen_string_literal: true

module System
  # The `adaptation_gate` provider — the fleet half of core's adaptation seam
  # (IMP-8c37b9e5ccd5, INC-2).
  #
  # `Ai::Provisioning::AdaptationDispatchService` composes nothing and decides
  # nothing about policy; it asks this class one question — may this
  # `adaptation_diff` plan be applied now? — and parks the plan when it cannot
  # get a usable answer. Registered in `PowernodeSystem::Engine` alongside
  # `provision_verifier`, which this mirrors: core resolves it through
  # `Powernode::ExtensionRegistry` and never names it.
  #
  # THE ANSWER COMES FROM THE EXISTING GATE. `Ai::InterventionPolicy`
  # resolution plus the Fleet Autonomy agent's `Ai::ApprovalChain`, reached
  # through `FleetAutonomyService#gate_action!` — the same call every other
  # fleet remediation makes, so an adaptation inherits policy resolution,
  # request dedup, the consent budget and the rejection cooldown for free. A
  # second approval namespace was explicitly rejected; nothing here mints its
  # own chain shape.
  #
  # Two invariants:
  #
  #   1. CORE'S BOUNDS MAY ONLY NARROW. `auto_apply_eligible: false` forces the
  #      require_approval arm regardless of what the operator policy says, so a
  #      policy can never widen core's replica ceiling. (Core independently
  #      refuses an answer that tries to, so this holds from both sides.)
  #
  #   2. ONE PLAN, ONE REQUEST. Re-asking about a plan already before the gate
  #      returns the existing request rather than minting a second — and
  #      returns AUTO_APPLY once that request is approved. That is what lets
  #      the sensor path (gated BEFORE composition) and the operator MCP path
  #      share a single queue, and what lets a routed plan be released by the
  #      ordinary approved lane instead of a bespoke callback.
  class AdaptationGate
    AUTO_APPLY = "auto_apply_within_bounds"
    ROUTED     = "routed"

    # Mirrors Ai::Provisioning::AdaptationDispatchService's authority values.
    # A POLICY grant is unattended and core's bounds bind it; an APPROVAL grant
    # carries a person's decision and releases an out-of-bounds plan.
    AUTHORITY_POLICY   = "policy"
    AUTHORITY_APPROVAL = "approval"

    # change_type -> fleet action category. These are the categories
    # DecisionEngine::SIGNAL_BINDINGS already routes the project.* lane
    # through, and the ones seeded as intervention policies on the Fleet
    # Autonomy agent — the mapping is not invented here.
    DEFAULT_CATEGORY = "project.adapt"
    CHANGE_TYPE_CATEGORIES = {
      "cost_control" => "project.cost_control"
    }.freeze

    FLEET_AGENT_NAME = "Fleet Autonomy"

    class << self
      # @return [Hash, nil] { disposition:, approval_request_id:, detail: } —
      #   nil when this account has no fleet gate at all, which core reads as
      #   "park the plan" rather than "proceed".
      def adaptation_disposition(account:, mission:, plan:, change_type:, auto_apply_eligible:)
        agent = fleet_agent(account)
        return nil unless agent

        category = action_category_for(change_type)

        # Already before the gate? Answer from the standing request instead of
        # minting a second one.
        if (existing = existing_request(account, plan))
          return from_existing(existing, auto_apply_eligible: auto_apply_eligible)
        end

        gate = ::System::Fleet::FleetAutonomyService
          .new(account: account, agent: agent)
          .gate_action!(
            category,
            metadata: metadata_for(mission, plan, change_type),
            reasoning: { summary: summary_for(mission, plan, change_type) },
            temporal_context: {},
            # The downgrade. An out-of-bounds plan never even asks the policy
            # whether it may proceed.
            force_policy: (auto_apply_eligible ? nil : "require_approval")
          )

        case gate[:decision]
        when :proceed
          { disposition: AUTO_APPLY, approval_request_id: nil,
            authority: AUTHORITY_POLICY,
            detail: "operator policy #{gate[:gate]}" }
        when :pending
          { disposition: ROUTED, approval_request_id: gate[:decision_record]&.id,
            detail: "awaiting operator decision (#{gate[:gate]})" }
        else
          # :blocked — the policy forbids this category, or the agent does not
          # permit it. Not cleared, and deliberately NOT reported as an absent
          # gate: the gate answered, and the answer was no.
          { disposition: ROUTED, approval_request_id: nil,
            detail: "blocked by policy: #{gate[:gate].presence || gate[:reason]}" }
        end
      end

      # Mint the pending `System::Fleet::RemediationOutcome` that closes the
      # sense -> act -> validate arc for the adaptation lane.
      #
      # Core calls this only after a healthy post-adapt verification, so
      # `acted_at` is the moment the adaptation actually landed. From here the
      # ORDINARY machinery takes over: `RemediationValidator#validate_due!`
      # scores the row on a later tick — EFFECTIVE when the fingerprint has
      # gone from the sense pass, INEFFECTIVE when it is still firing. Nothing
      # re-senses on core's behalf, and no second scoring path is introduced.
      #
      # This is the row `RemediationValidator#record_proceeded!` deliberately
      # does NOT create: a proposal is not a remediation, and scoring one at
      # proposal time marked every proposal ineffective on the next tick.
      #
      # @return [System::Fleet::RemediationOutcome, nil]
      def record_adaptation_outcome!(account:, mission:, plan:, fingerprint:, signal_kind:)
        return nil if fingerprint.blank?

        # One pending outcome per fingerprint — same rule record_proceeded!
        # uses. A second adaptation against a still-unresolved condition is the
        # same unresolved problem, not a fresh remediation to score.
        if ::System::Fleet::RemediationOutcome.pending
                                              .exists?(account_id: account.id, fingerprint: fingerprint)
          return nil
        end

        data = plan_data(plan)
        payload = data["signal_payload"].is_a?(Hash) ? data["signal_payload"] : {}
        now = Time.current

        ::System::Fleet::RemediationOutcome.create!(
          account: account,
          agent_id: fleet_agent(account)&.id,
          signal_kind: signal_kind.presence || data["signal_kind"].to_s,
          fingerprint: fingerprint.to_s,
          action_category: action_category_for(data["change_type"]),
          correlation_id: payload["correlation_id"].presence,
          resource_ref: mission.id,
          status: "pending",
          acted_at: now,
          settle_until: now + ::System::Fleet::RemediationValidator::SETTLE_WINDOW,
          metadata: {
            "gate" => "adaptation_applied",
            "plan_id" => plan.id,
            # Provenance for the validator's sensor-failure guard: absence of
            # this fingerprint is only evidence on ticks where its owning
            # sensor actually ran.
            "sensor" => payload["_sensor"].presence
          }.compact
        )
      end

      def action_category_for(change_type)
        CHANGE_TYPE_CATEGORIES.fetch(change_type.to_s, DEFAULT_CATEGORY)
      end

      private

      def fleet_agent(account)
        ::Ai::Agent.resolve_for(account.id, name: FLEET_AGENT_NAME, agent_type: "monitor")
                   &.tap { |a| a.resolving_account = account }
      rescue StandardError => e
        Rails.logger.warn("[AdaptationGate] fleet agent lookup failed: #{e.message}")
        nil
      end

      # The standing request for THIS plan, if any. Keyed on the plan id we
      # stamp into the request payload, so it is exact rather than a heuristic
      # over action_category + mission.
      def existing_request(account, plan)
        return nil unless defined?(::Ai::ApprovalRequest)

        ::Ai::ApprovalRequest
          .where(account_id: account.id, source_type: "system_fleet")
          .where("request_data->'payload'->>'plan_id' = ?", plan.id)
          .order(created_at: :desc)
          .first
      rescue StandardError => e
        Rails.logger.warn("[AdaptationGate] existing-request lookup failed: #{e.message}")
        nil
      end

      # An approval RELEASES the plan, in bounds or out. `authority: approval`
      # is what tells core a PERSON granted this rather than a policy — core
      # enforces its bounds against an unattended policy grant, and defers to a
      # human who looked at the plan and said yes. The flag is declared here,
      # never inferred by core from the presence of a request id.
      def from_existing(request, auto_apply_eligible:)
        if request.status.to_s == "approved"
          return { disposition: AUTO_APPLY, approval_request_id: request.id,
                   authority: AUTHORITY_APPROVAL,
                   detail: "released by operator approval" }
        end

        { disposition: ROUTED, approval_request_id: request.id,
          detail: "existing request is #{request.status}" }
      end

      def metadata_for(mission, plan, change_type)
        data = plan_data(plan)
        payload = data["signal_payload"].is_a?(Hash) ? data["signal_payload"] : {}

        {
          "mission_id" => mission.id,
          "plan_id" => plan.id,
          "change_type" => change_type.to_s,
          # execute_approved! replays a request by rebuilding a Signal from
          # these keys, so carry them in the shape it expects.
          "signal_kind" => data["signal_kind"].to_s,
          "signal_fingerprint" => data["signal_fingerprint"].to_s.presence,
          "correlation_id" => payload["correlation_id"].presence
        }.compact
      end

      def summary_for(mission, plan, change_type)
        steps = plan.steps.count
        "Adaptation (#{change_type}) for mission #{mission.name}: #{steps} step(s)"
      end

      def plan_data(plan)
        data = plan.plan_data
        data.is_a?(Hash) ? data : {}
      end
    end
  end
end
