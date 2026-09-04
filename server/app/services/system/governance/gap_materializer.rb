# frozen_string_literal: true

module System
  module Governance
    # MATERIALISE arm of the Platform Architect's sense → propose → materialise
    # → verify loop (HIER-P3, proposal §2 Phase 3 step 3).
    #
    # A governance gap the RUNTIME can close — a lineage edge, a delegation
    # policy, a skill binding, a prompt refinement on an existing skill — is
    # applied here through the same seams the seeds and the tools use
    # (Ai::Agents::HierarchyWriter, Ai::AgentSkill,
    # Ai::SelfImprovement::SkillRefinementService), never by editing a global
    # in place without a record: every application writes ONE AuditLog row and
    # ONE FleetEvent, both naming the offer (Ai::ImprovementRecommendation) the
    # propose executor filed for the gap, and closes that offer as `applied`.
    #
    # THE GATE IS THE RULING (operator ruling 2026-09-03 #3). Each kind names
    # the Ai::InterventionPolicy category it materialises under, and the
    # category — not this class — decides whether the write happens now or
    # parks for an operator:
    #
    #   skill_binding      dev.skill_refine   } the P2B-ENG trust-conditioned
    #   prompt_refinement  dev.prompt_refine  } PAIR: auto_approve from the
    #                                          `trusted` tier, require_approval
    #                                          below it (the SAME rows
    #                                          SelfImprovementTool gates on)
    #   lineage_edge       dev.governance_materialize — STRUCTURAL: declared
    #   delegation_policy  dev.governance_materialize   require_approval on the
    #                                                   Platform Architect,
    #                                                   never unlocked by trust
    #
    # Resolution goes through Ai::AutonomyGate, so a parked materialisation is
    # an Ai::DeferredOperation with an ApprovalRequest on the Platform
    # Architect's chain, and approval REPLAYS it through `.execute` below (the
    # gate's executor contract) as the same principal. An unmatched category
    # meets the require_approval default, so a category NO row covers parks and
    # never applies.
    #
    # BUT THE REFINE CATEGORIES ARE COVERED ON EVERY ACCOUNT, AND THE TRUST
    # CONDITION ABOVE IS NOT WHAT DECIDES THERE (IMP-a51963f8717f, proposal §5
    # ruling 11c). Core's Ai::Engineering::ReleaseDispatchFloorSeeder writes a
    # scope-"global", agent-less `auto_approve` FLOOR for dev.skill_refine and
    # dev.prompt_refine on EVERY account — it exists so the principals that
    # refine a skill over MCP and own no row (an operator's `mcp_client`
    # identity, a dev-cell instance principal) keep running. The
    # trust-conditioned PAIR that outranks a floor is seeded only on the
    # "Powernode Admin" account's canonicals, so on any OTHER account the
    # acting Platform Architect (the per-account clone AgentResolver mints)
    # owns no refine row and Ai::InterventionPolicyService#resolve — which
    # admits scope-"global" rows for an agent caller — lands on the floor.
    #
    # Net: a skill binding or prompt refinement is trust-conditioned on the
    # admin account and applies at ANY tier elsewhere. The STRUCTURAL kinds are
    # unaffected: no floor covers dev.governance_materialize, so they park
    # everywhere. governance_gap_propose_executor_spec pins both states.
    #
    # The existing MCP tools (set_delegation_policy, attach_skill_to_agent,
    # mutate_skill) are deliberately NOT called from here: each carries its
    # own gate, and a gated call nested under this gate would park TWICE for
    # one decision. The seams beneath them are what this class writes through.
    class GapMaterializer
      AUDIT_ACTION = "system.governance.gap_materialized"
      AUDITED_ACTIONS = [ AUDIT_ACTION ].freeze
      EVENT_KIND = "fleet.governance_gap_materialized"

      STRUCTURAL_CATEGORY = "dev.governance_materialize"
      CATEGORY_BY_KIND = {
        "lineage_edge"      => STRUCTURAL_CATEGORY,
        "delegation_policy" => STRUCTURAL_CATEGORY,
        "skill_binding"     => "dev.skill_refine",
        "prompt_refinement" => "dev.prompt_refine"
      }.freeze
      KINDS = CATEGORY_BY_KIND.keys.freeze

      SPAWN_REASON = "governance_gap"

      class << self
        def category_for(kind)
          CATEGORY_BY_KIND.fetch(kind.to_s) do
            raise ArgumentError, "unknown materialization kind #{kind.inspect} (known: #{KINDS.join(', ')})"
          end
        end

        # Ai::AutonomyGate replay entry point — runs on auto-approve now and on
        # the approved replay later, as the operation's own principal.
        def execute(params, deferred_operation:)
          params = (params || {}).deep_stringify_keys
          account = deferred_operation.account
          agent = deferred_operation.ai_agent
          # `send` on purpose: #apply! is PRIVATE so this class method and the
          # gate's replay are its only doors. A public writer would be a
          # second, UNGATED entry into every governance write below — the
          # exact structural gate the increment exists to enforce.
          new(account: account, agent: agent).send(:apply!, params, deferred_operation: deferred_operation)
        end
      end

      def initialize(account:, agent: nil)
        raise ArgumentError, "account is required" if account.nil?

        @account = account
        @agent = agent
      end

      # Gate and (when policy allows) apply one materialisation.
      #
      # @param kind [String] one of KINDS
      # @param params [Hash] the sensor's materialization hash (kind-specific keys)
      # @param offer [Ai::ImprovementRecommendation, nil] the offer this closes
      # @param fingerprint [String] the gap's fingerprint (dedup key for a parked op)
      # @return [Hash] status: "applied" | "pending" | "blocked", plus the record ids
      def call(kind:, params:, fingerprint:, offer: nil)
        kind = kind.to_s
        category = self.class.category_for(kind)
        payload = params.to_h.deep_stringify_keys.merge(
          "kind" => kind, "fingerprint" => fingerprint.to_s, "offer_id" => offer&.id
        ).compact

        if (open = open_operation(category, fingerprint))
          return { status: "pending", action_category: category, deferred_operation_id: open.id,
                   approval_request_id: open.approval_request_id, deduped: true }
        end

        result = ::Ai::AutonomyGate.evaluate(
          action_category: category,
          executor_class: self.class.name,
          params: payload,
          account: @account,
          agent: @agent,
          description: "Governance gap materialisation (#{kind}): #{fingerprint}"
        )

        case result.decision
        when :proceed
          { status: "applied", action_category: category, deferred_operation_id: result.deferred_operation&.id }
            .merge((result.result.is_a?(Hash) ? result.result.symbolize_keys : {}).slice(:written, :resource_type, :resource_id))
        when :pending
          { status: "pending", action_category: category, deferred_operation_id: result.deferred_operation&.id,
            approval_request_id: result.approval_request&.id }
        else
          { status: "blocked", action_category: category, error: result.error }
        end
      end

      private

      # The write itself. PRIVATE, and reached ONLY through .execute — the
      # Ai::AutonomyGate auto-proceed or the approved replay. Never called from
      # the propose executor, and never a public door: an ungated caller here
      # would write a lineage edge or a delegation policy with no
      # Ai::InterventionPolicy resolution at all.
      def apply!(params, deferred_operation: nil)
        params = params.to_h.deep_stringify_keys
        kind = params.fetch("kind")
        written = case kind
        when "lineage_edge"      then apply_lineage_edge(params)
        when "delegation_policy" then apply_delegation_policy(params)
        when "skill_binding"     then apply_skill_binding(params)
        # No sensor detector stamps "prompt_refinement" yet — the kind is a
        # gated, versioned seam for a future prompt-drift detector (and for the
        # Platform Architect's own refinements), not something the tick
        # produces. Documented as such in docs/runbooks/governance-gaps.md.
        when "prompt_refinement" then apply_prompt_refinement(params)
        else raise ArgumentError, "unknown materialization kind #{kind.inspect}"
        end

        offer = find_offer(params["offer_id"])
        record!(kind: kind, params: params, written: written, offer: offer, deferred_operation: deferred_operation)
        close_offer!(offer, kind: kind, written: written, deferred_operation: deferred_operation)

        { "applied" => true, "kind" => kind, "written" => written, "offer_id" => offer&.id }
      end

      def open_operation(category, fingerprint)
        ::Ai::DeferredOperation
          .where(account: @account, action_category: category, executor_class: self.class.name)
          .where(status: %w[pending approved executing])
          .where("params->>'fingerprint' = ?", fingerprint.to_s)
          .order(:created_at)
          .first
      end

      def hierarchy
        @hierarchy ||= ::Ai::Agents::HierarchyWriter.new(account: @account)
      end

      def apply_lineage_edge(params)
        child = ::Ai::Agent.find(params.fetch("child_agent_id"))
        parent = ::Ai::Agent.find(params.fetch("parent_agent_id"))
        edge = hierarchy.attach!(child: child, parent: parent, spawn_reason: SPAWN_REASON,
                                 metadata: { "agent_key" => params["agent_key"], "offer_id" => params["offer_id"] }.compact)
        { "resource_type" => edge.class.name, "resource_id" => edge.id,
          "child_agent_id" => child.id, "parent_agent_id" => parent.id }
      end

      def apply_delegation_policy(params)
        agent = ::Ai::Agent.find(params.fetch("agent_id"))
        attrs = params.fetch("attributes").to_h.symbolize_keys
        policy = hierarchy.ensure_delegation_policy!(agent: agent, **attrs)
        { "resource_type" => policy.class.name, "resource_id" => policy.id, "agent_id" => agent.id }
      end

      def apply_skill_binding(params)
        bindings = Array(params.fetch("bindings"))
        raise ArgumentError, "skill_binding needs at least one binding" if bindings.empty?

        rows = bindings.map.with_index do |b, i|
          agent = ::Ai::Agent.find(b.fetch("agent_id"))
          skill = ::Ai::Skill.find(b.fetch("skill_id"))
          row = ::Ai::AgentSkill.find_or_initialize_by(ai_agent_id: agent.id, ai_skill_id: skill.id)
          row.assign_attributes(is_active: true, priority: row.priority.presence || 100 + i)
          row.save! if row.new_record? || row.changed?
          { "agent_skill_id" => row.id, "agent_id" => agent.id, "skill_id" => skill.id, "skill_slug" => skill.slug }
        end
        { "resource_type" => "Ai::AgentSkill", "resource_id" => rows.first["agent_skill_id"], "bindings" => rows }
      end

      def apply_prompt_refinement(params)
        skill = ::Ai::Skill.find(params.fetch("skill_id"))
        result = ::Ai::SelfImprovement::SkillRefinementService.new(account: @account, agent: @agent)
                                                              .refine!(skill: skill,
                                                                       system_prompt: params.fetch("system_prompt"),
                                                                       reason: params["reason"].to_s)
        { "resource_type" => "Ai::SkillVersion", "resource_id" => result.version&.id,
          "skill_id" => skill.id, "changed" => result.changed }
      end

      def find_offer(offer_id)
        return nil if offer_id.blank?

        ::Ai::ImprovementRecommendation.find_by(id: offer_id, account: @account)
      end

      # ONE audit row and ONE fleet event per application, both naming the
      # offer. The audit action is registered by lib/powernode_system/engine.rb
      # beside the reconciler's re-home token; an unregistered token would make
      # AuditLog#action fail validation and roll the write back.
      def record!(kind:, params:, written:, offer:, deferred_operation:)
        ::AuditLog.log_action(
          action: AUDIT_ACTION,
          resource: offer || @agent || @account,
          user: nil,
          account: @account,
          new_values: written,
          source: "system",
          severity: "medium",
          risk_level: "medium",
          metadata: {
            "kind" => kind,
            "fingerprint" => params["fingerprint"],
            "offer_id" => offer&.id,
            "agent_id" => @agent&.id,
            "deferred_operation_id" => deferred_operation&.id,
            "action_category" => self.class.category_for(kind),
            "reason" => "governance gap materialised by the Platform Architect (HIER-P3)"
          }.compact
        )

        ::System::Fleet::EventBroadcaster.emit!(
          account: @account,
          kind: EVENT_KIND,
          severity: :medium,
          payload: {
            "kind" => kind,
            "fingerprint" => params["fingerprint"],
            "offer_id" => offer&.id,
            "agent_id" => @agent&.id,
            "deferred_operation_id" => deferred_operation&.id,
            "written" => written
          }.compact,
          source: "governance.gap_materializer",
          correlation_id: params["fingerprint"].presence
        )
      end

      def close_offer!(offer, kind:, written:, deferred_operation:)
        return unless offer
        return unless %w[pending approved].include?(offer.status)

        evidence = (offer.evidence || {}).merge(
          "materialization" => (offer.evidence&.dig("materialization") || {}).merge(
            "status" => "applied", "kind" => kind, "written" => written,
            "deferred_operation_id" => deferred_operation&.id, "applied_at" => Time.current.iso8601
          ).compact
        )
        offer.update!(status: "applied", applied_at: Time.current, evidence: evidence)
      end
    end
  end
end
