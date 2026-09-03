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
  # resolution plus the owning agent's `Ai::ApprovalChain`, reached through
  # `FleetAutonomyService#gate_action!` on the gate `#for_owner` returns for
  # the category's declared owner — the Capacity Manager since HIER-P2DECL,
  # Fleet Autonomy as the fallback while that agent is unseeded — the same
  # call every other fleet remediation makes, so an adaptation inherits policy
  # resolution, request dedup, the consent budget and the rejection cooldown
  # for free. A second approval namespace was explicitly rejected; nothing
  # here mints its own chain shape.
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
    # THIS CLASS IS A ROUTER, and for a long time nothing knew it.
    #
    # CHANGE_TYPE_CATEGORIES below maps a change_type onto a
    # `project.<change_type>` action category and hands it to
    # FleetAutonomyService#gate_action! — four of which
    # DecisionEngine::SIGNAL_BINDINGS never names. RoutedLaneGuard read only
    # the engine's set, so a MISSING policy row for those four took its quiet
    # `not_permitted` arm and arrived back here labelled "blocked by policy"
    # (IMP-7a6c9a70e050). Declaring the routing is what makes the guard see it.
    extend ::System::Autonomy::ActionCategoryRouter

    AUTO_APPLY = "auto_apply_within_bounds"
    ROUTED     = "routed"

    # Mirrors Ai::Provisioning::AdaptationDispatchService's authority values.
    # A POLICY grant is unattended and core's bounds bind it; an APPROVAL grant
    # carries a person's decision and releases an out-of-bounds plan.
    AUTHORITY_POLICY   = "policy"
    AUTHORITY_APPROVAL = "approval"

    # change_type -> fleet action category.
    #
    # NOT invented here: these are the six categories
    # `system_provisioning_intervention_policies.rb` seeds on the Fleet
    # Autonomy agent, and the six `Ai::InterventionPolicy::STATIC_CATEGORIES`
    # declares. Each carries its own seeded policy — scale_horizontal is
    # `auto_approve` (deliberately paired with core's watch_policies ceiling,
    # which the seed's own comment names as the re-check), while relocate,
    # schema_change and security_change are `require_approval`.
    #
    # Resolving at CHANGE_TYPE granularity rather than collapsing everything
    # onto `project.adapt` is what makes those five policies reachable. A
    # collapsed mapping consulted `project.adapt` (notify_and_proceed) for a
    # cross-region relocate, so an operator who set `project.relocate` to
    # require_approval — the seeded default — would have had no effect. Core's
    # bounds check happens to park a relocate anyway, but that is a guard on a
    # different branch, not the operator's policy being honored.
    #
    # DecisionEngine::SIGNAL_BINDINGS maps to the coarse `project.adapt` /
    # `project.cost_control` pair because a SIGNAL KIND is coarser than a
    # change type; here the change type is known, so the specific category is.
    DEFAULT_CATEGORY = "project.adapt"
    CHANGE_TYPE_CATEGORIES = {
      "scale_horizontal" => "project.scale_horizontal",
      "cost_control" => "project.cost_control",
      "relocate" => "project.relocate",
      "schema_change" => "project.schema_change",
      "security_change" => "project.security_change"
    }.freeze

    # Approval states that will never release a plan. Retrying the gate cannot
    # help, so the proposal has to be CLOSED rather than held — see #close_plan!.
    TERMINAL_REQUEST_STATUSES = %w[rejected expired cancelled].freeze

    # DECLARED CAUSE for a ROUTED disposition that minted no request
    # (IMP-fec9abb225c6). Three unrelated conditions produce that shape and the
    # consumer has to tell them apart: one is a configuration gap worth waking
    # somebody for, one is the operator's own answer, one is a missing chain.
    #
    # Declared, never inferred — the same discipline core already applies to
    # `authority`. The consumer used to infer "no permitting policy" from
    # (ROUTED && approval_request_id.nil?), which is true of all three, so an
    # operator who had just REJECTED an adaptation was sent hunting a policy gap
    # that did not exist.
    CAUSE_POLICY_BLOCKED     = "policy_blocked"
    CAUSE_REJECTION_COOLDOWN = "suppressed_by_rejection_cooldown"
    CAUSE_NO_REQUEST_STORE   = "no_chain_or_request_store"
    CAUSE_UNKNOWN            = "unknown"

    # A FIFTH CAUSE, split out of CAUSE_POLICY_BLOCKED (IMP-7a6c9a70e050).
    # `permitted_actions` IS the policy-row set, so the gate's :blocked arm
    # covers two opposite situations: the operator answered no, and nobody has
    # ever configured this lane. The second is a deploy defect — db:seed is
    # first-boot-only — and telling an operator their policy blocked it sends
    # them to tune a row that does not exist.
    #
    # TAKEN FROM THE SEAM, never re-spelled. RoutedLaneGuard is what decides a
    # lane is routed-but-unseeded and what stamps the gate value, so it owns the
    # word; aliasing keeps one source of truth. And a copied literal could not
    # be caught later — frozen string literals are interned globally (the pragma
    # is hook-enforced repo-wide), so a duplicate `"policy_missing"` is the SAME
    # object and passes every equality and identity check right up until someone
    # edits one of the two spellings.
    CAUSE_POLICY_MISSING = ::System::Autonomy::RoutedLaneGuard::GATE_POLICY_MISSING

    # FleetAutonomyService's suppression vocabulary -> ours. Anything unmapped
    # stays CAUSE_UNKNOWN, which the consumer treats as loudly as a real gap:
    # not knowing why nothing was minted is itself worth reporting, and quieting
    # by default is how the silent-failure this alarm exists for got in.
    SUPPRESSION_CAUSES = {
      ::System::Fleet::FleetAutonomyService::SUPPRESSION_REJECTION_COOLDOWN => CAUSE_REJECTION_COOLDOWN,
      ::System::Fleet::FleetAutonomyService::SUPPRESSION_NO_REQUEST_STORE => CAUSE_NO_REQUEST_STORE
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
          return from_existing(existing, plan: plan, auto_apply_eligible: auto_apply_eligible)
        end

        # HIER-P2DECL: the project.* categories are declared on the Capacity
        # Manager (PolicyDeclarations::CAPACITY_MANAGER_POLICIES), so this
        # router gates under that agent exactly as the DecisionEngine's three
        # project_* bindings do — through #for_owner, which resolves the
        # declared owner override-aware and falls back to Fleet Autonomy (with
        # a fleet.owner_agent_missing event) until wave 2 seeds it. Gating as
        # Fleet Autonomy directly would resolve against rows the reconciler
        # has moved off it: the "row the gate never reads" defect, one router
        # over.
        #
        # COST OF THE FALLBACK, until wave 2 seeds the Capacity Manager: the
        # service memoizes owner gates PER INSTANCE (@owner_gates) and this
        # router builds a fresh one per call, so every adaptation disposition
        # writes one fleet.owner_agent_missing FleetEvent — unlike the tick,
        # which builds its service once and warns once. Accepted, not hoisted:
        # no sensor consumes OWNER_MISSING_EVENT_KIND, the volume is one row
        # per plan evaluated, and it is a visible countdown on work wave 2
        # ends. adaptation_gate_spec pins the one-event-per-disposition shape,
        # so hoisting later is a spec change, not a silent one.
        owner_gate = ::System::Fleet::FleetAutonomyService
          .new(account: account, agent: agent)
          .for_owner(::System::Governance::PolicyDeclarations.owner_of(category))
        gate = owner_gate.gate_action!(
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
          request_id = gate[:decision_record]&.id
          return { disposition: ROUTED, approval_request_id: request_id,
                   detail: "awaiting operator decision (#{gate[:gate]})" } if request_id

          # PENDING WITH NOTHING TO PEND ON. gate_action! reports :pending
          # whenever the policy says require_approval, but create_pending_approval
          # declines to mint inside the rejection cooldown and cannot mint at all
          # without an approval chain. Nothing exists for an operator to answer,
          # so this is a held plan with no holder — and the two causes want
          # opposite handling, one quiet and one loud.
          cause = SUPPRESSION_CAUSES.fetch(gate[:suppression].to_s, CAUSE_UNKNOWN)
          { disposition: ROUTED, approval_request_id: nil, cause: cause,
            detail: detail_for_cause(cause, gate) }
        else
          # :blocked — two OPPOSITE failures share this arm, and which one it is
          # decides where the operator is sent (IMP-7a6c9a70e050).
          #
          #   * an unseeded lane   — nothing answered; the configuration is
          #     absent. RoutedLaneGuard stamps GATE_POLICY_MISSING because this
          #     class declares the category routed. Re-run the seed.
          #   * anything else      — the gate answered, and the answer was no.
          #     Deliberately NOT reported as an absent gate.
          #
          # Read the GATE, never infer from the reason string: "not_permitted"
          # is what both looked like before the guard could see this router's
          # categories, which is exactly how the first reading got lost.
          if gate[:gate] == CAUSE_POLICY_MISSING
            { disposition: ROUTED, approval_request_id: nil,
              cause: CAUSE_POLICY_MISSING,
              detail: "no intervention policy row for #{category} on the " \
                      "#{owner_gate.agent&.name || FLEET_AGENT_NAME} agent — run the governance " \
                      "reconcile (rake system:governance:reconcile) against this database" }
          else
            { disposition: ROUTED, approval_request_id: nil,
              cause: CAUSE_POLICY_BLOCKED,
              detail: "blocked by policy: #{gate[:gate].presence || gate[:reason]}" }
          end
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
      # @param status [String] "pending" for a landed adaptation the validator
      #   will score on a later tick, or "ineffective" for one that FAILED its
      #   post-adapt verification.
      def record_adaptation_outcome!(account:, mission:, plan:, fingerprint:, signal_kind:, status: "pending")
        return nil if fingerprint.blank?

        # A FAILED adaptation is scored NOW, not left pending. Verification has
        # already answered the question the settle window exists to ask, and
        # without this row nothing marks the lane as failing: the validator's
        # proposal exemption means record_proceeded! never scores this lane, so
        # an adaptation that runs and breaks every time would look identical to
        # one nobody had gotten to yet. This row is what lets F3-11's
        # ineffective_streak escalate a persistently failing adaptation.
        return settle_failed_outcome!(account, plan, fingerprint, signal_kind) if status == "ineffective"

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

      # `validated_at` is set because RemediationOutcome.ineffective_streak
      # orders by it — an unset column would sort the row out of the streak it
      # is supposed to contribute to. A pending row THIS PLAN minted is the same
      # unresolved condition, so it is settled in place rather than duplicated.
      #
      # IMP-fec9abb225c6 (5) — scoped to this plan's own row. The lookup used to
      # be (account_id, fingerprint) alone, which also matches rows minted by a
      # different lane, or by a previous still-settling SUCCESSFUL adaptation for
      # the same fingerprint. A later failure could therefore re-label an earlier
      # success as `ineffective`.
      #
      # That is instrument corruption rather than a cosmetic bug:
      # RemediationOutcome is the ground truth the LEARN step reads, so the
      # re-label both fabricates a data point and pushes two genuine failures
      # toward STUCK_STREAK_THRESHOLD. Both mints already carry
      # metadata["plan_id"], so the scoping needs no new column.
      def settle_failed_outcome!(account, plan, fingerprint, signal_kind)
        now = Time.current
        pending = ::System::Fleet::RemediationOutcome.pending
                    .where(account_id: account.id, fingerprint: fingerprint)
                    .where("metadata->>'plan_id' = ?", plan.id.to_s)
                    .first
        if pending
          pending.update!(status: "ineffective", validated_at: now)
          return pending
        end

        data = plan_data(plan)
        payload = data["signal_payload"].is_a?(Hash) ? data["signal_payload"] : {}

        ::System::Fleet::RemediationOutcome.create!(
          account: account,
          agent_id: fleet_agent(account)&.id,
          signal_kind: signal_kind.presence || data["signal_kind"].to_s,
          fingerprint: fingerprint.to_s,
          action_category: action_category_for(data["change_type"]),
          correlation_id: payload["correlation_id"].presence,
          resource_ref: data["mission_id"].presence,
          status: "ineffective",
          acted_at: now,
          settle_until: now,
          validated_at: now,
          metadata: { "gate" => "adaptation_failed", "plan_id" => plan.id }
        )
      end

      def action_category_for(change_type)
        CHANGE_TYPE_CATEGORIES.fetch(change_type.to_s, DEFAULT_CATEGORY)
      end

      # The ActionCategoryRouter declaration — EXACTLY what #action_category_for
      # can return, derived from the same constants rather than restated, so a
      # new change_type cannot be routed without becoming visible to
      # RoutedLaneGuard.
      def routed_action_categories
        [ DEFAULT_CATEGORY, *CHANGE_TYPE_CATEGORIES.values ].uniq.freeze
      end

      private

      # The operator-facing sentence for each cause. Kept beside the constants
      # because the words are the whole point of the fix: the previous text said
      # "blocked by policy" for every one of these.
      def detail_for_cause(cause, gate)
        case cause
        when CAUSE_REJECTION_COOLDOWN
          "suppressed by the rejection cooldown — an operator declined this recently"
        when CAUSE_NO_REQUEST_STORE
          "no fleet approval chain to route to (#{gate[:gate]})"
        else
          "held with no request minted (#{gate[:gate]})"
        end
      end

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
      def from_existing(request, plan:, auto_apply_eligible:)
        status = request.status.to_s

        if status == "approved"
          return { disposition: AUTO_APPLY, approval_request_id: request.id,
                   authority: AUTHORITY_APPROVAL,
                   detail: "released by operator approval" }
        end

        if TERMINAL_REQUEST_STATUSES.include?(status)
          close_plan!(plan, status)
          return { disposition: ROUTED, approval_request_id: request.id,
                   detail: "request #{status} — proposal closed, the mission may propose again" }
        end

        { disposition: ROUTED, approval_request_id: request.id,
          detail: "existing request is #{status}" }
      end

      # Reflect the decision onto the PLAN, not just the request.
      #
      # Nothing else does. Core transitions a plan only on dispatch, and dispatch
      # only happens on AUTO_APPLY — so a rejected proposal sat in `draft`
      # forever, and DecisionEngine's one-in-flight-proposal brake stayed engaged
      # against a condition that was still breaching. The fleet chain is 4h with
      # timeout_action "reject", so this is the DEFAULT path for any routed
      # adaptation an operator does not answer in time, not an edge case.
      #
      # The gate owns the approval lifecycle, so it owns closing the plan that
      # approval was about.
      # IMP-fec9abb225c6 (1) — close only a plan that has NOT been dispatched.
      #
      # The guard used to be `plan.status == "rejected"`, i.e. everything else
      # was fair game, and Ai::GoalPlan#reject! is a bare update! with no state
      # machine. So a plan whose latest approval request became cancelled or
      # expired AFTER dispatch — which needs a mid-execution policy change, not
      # the ordinary approve-then-dispatch path — flipped to `rejected` while
      # its appended steps kept running on the mission's live plan.
      #
      # That corrupts two things at once: settle! scopes to status "executing",
      # so the plan can never settle and no RemediationOutcome is minted for it;
      # and in_flight_adaptation_plan stops seeing it, so the next breach
      # composes a SECOND plan and appends more steps while the first set is
      # still running.
      #
      # Shares DecisionEngine's constant rather than restating %w[draft
      # validated]: the two must agree about what "not yet dispatched" means,
      # and a copy is free to drift. Same extension, so no core -> extension
      # dependency is introduced.
      def close_plan!(plan, status)
        return if plan.nil?
        unless ::System::Fleet::DecisionEngine::UNDISPATCHED_PROPOSAL_STATUSES.include?(plan.status.to_s)
          return
        end

        plan.reject!(reason: "adaptation approval #{status}")
      rescue StandardError => e
        # Never let bookkeeping turn a decided request back into an undecided
        # one — the disposition above is still the honest answer.
        Rails.logger.warn("[AdaptationGate] could not close plan #{plan&.id}: #{e.message}")
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
