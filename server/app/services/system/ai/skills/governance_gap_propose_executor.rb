# frozen_string_literal: true

module System
  module Ai
    module Skills
      # PROPOSE arm of the Platform Architect's loop (HIER-P3, proposal §2
      # Phase 3 step 2): one `system.governance_gap` signal becomes ONE
      # reviewable Ai::ImprovementRecommendation — the offer IS the human gate.
      #
      # Routed by DecisionEngine under `dev.campaign_propose` (auto_approve on
      # the Platform Architect: proposing is free, landing is not) and bound to
      # the Platform Architect — a CORE canonical, the first extension executor
      # to bind one (SkillBindings::AGENT_ALIASES "platform_architect").
      #
      # IDEMPOTENT ON THE GAP. The offer's evidence carries the signal's
      # fingerprint; a re-detection UPDATES the open offer (detections count,
      # latest severity, latest spec) and never files a second — the same
      # contract Ai::Tools::ImprovementTool#create_improvement keeps for the
      # code-quality offers, re-stated here because that tool admits only its
      # CODE_TYPES and this lane files capability_gap / team_composition /
      # skill_creation / prompt_refinement (RECOMMENDATION_TYPES all).
      #
      # An offer, never an Ai::AgentProposal: offers are the code path (an
      # approved one is promoted into a dev-improve task); AgentProposal
      # remains the runtime-materialisation vocabulary of other lanes.
      #
      # MATERIALISE. For a gap the runtime can close (the sensor stamps a
      # `materialization` hash), the executor also hands it to
      # System::Governance::GapMaterializer, which gates it under the ruling-3
      # categories — a refinement (skill binding, prompt) applies at once for a
      # `trusted` Platform Architect and parks below it; a structural change
      # (edge, delegation) parks whatever the tier. An applied materialisation
      # closes the offer; a parked one is recorded on it and replays on
      # approval. Nothing is materialised under dry_run.
      class GovernanceGapProposeExecutor < BaseSkillExecutor
        skill_descriptor(
          name:        "governance_gap_propose",
          description: "File (or update) the one reviewable improvement offer for a governance gap the fleet tick detected — a declared category nobody owns, an agent without skills, a lane bound to no skill, an executor without a catalog row, a missing lineage edge or delegation policy — and materialise the runtime-closable ones under the Platform Architect's gates",
          category:    "governance",
          requires_approval: true,
          action_category:   "dev.campaign_propose",
          blast_radius: :low,
          inputs: {
            gap:         { type: "object", required: true,
                           description: "GovernanceGapSensor payload: gap_kind, subject, recommendation_type, summary, files, materialization" },
            fingerprint: { type: "string", required: true, description: "The signal's fingerprint — the offer's dedup key" },
            severity:    { type: "string", required: false, description: "Signal severity (low|medium|high|critical)" },
            dry_run:     { type: "boolean", required: false, description: "Report the plan; file and materialise nothing" }
          },
          outputs: {
            offer_id:            :string,
            deduped:             :boolean,
            recommendation_type: :string,
            materialization:     :object
          }
        )

        binds_to "platform_architect"

        TYPES = ::Ai::ImprovementRecommendation::RECOMMENDATION_TYPES
        PROPOSED_BY = "platform-architect"

        protected

        def validate_inputs!(inputs)
          super

          gap = inputs[:gap]
          raise ArgumentError, "gap must be a Hash" unless gap.is_a?(Hash)

          type = gap.deep_stringify_keys["recommendation_type"].to_s
          return if TYPES.include?(type)

          raise ArgumentError, "gap.recommendation_type #{type.inspect} is not an Ai::ImprovementRecommendation type " \
                               "(#{TYPES.join(', ')})"
        end

        def perform(gap:, fingerprint:, severity: nil, dry_run: false)
          gap = gap.deep_stringify_keys
          fingerprint = fingerprint.to_s
          spec = build_spec(gap, fingerprint, severity)

          if dry_run
            return success(dry_run: true, recommendation_type: spec[:type], title: spec[:title],
                           materialization: gap["materialization"])
          end

          offer, deduped = file_offer!(spec, gap, fingerprint)
          materialization = materialize!(offer, gap, fingerprint)

          success(
            offer_id: offer.id,
            deduped: deduped,
            recommendation_type: spec[:type],
            title: spec[:title],
            materialization: materialization
          )
        end

        private

        def build_spec(gap, fingerprint, severity)
          kind = gap["gap_kind"].to_s
          subject = gap["subject"].to_s
          {
            type: gap["recommendation_type"].to_s,
            title: "Governance gap (#{kind}): #{subject}",
            description: gap["summary"].to_s,
            files: Array(gap["files"]).map(&:to_s),
            fix: fix_for(gap),
            severity: (severity.presence || gap["severity"]).to_s,
            fingerprint: fingerprint,
            kind: kind,
            subject: subject
          }
        end

        # The concrete, reviewable spec: what closes the gap, and where.
        def fix_for(gap)
          kind = gap["gap_kind"].to_s
          subject = gap["subject"].to_s
          case kind
          when "category_unowned"
            "Declare #{subject} in the PolicyDeclarations set of the agent that owns it (a new agent set needs an " \
            "AGENT_IDENTITIES entry, a POLICY_SETS entry and the owner on its DecisionEngine binding), or " \
            "deregister it. PolicyReconciler writes the row on the next boot."
          when "agent_without_skills"
            "Bind at least one executor to #{gap['agent_name'] || subject} (binds_to in the executor, a catalog row " \
            "in system_skills_seed.rb); a registry-declared pair with no row is materialised as an Ai::AgentSkill " \
            "binding under dev.skill_refine."
          when "binding_without_skill"
            "Give #{subject} an executor (skill:) or a REMEDIATION_APPLIERS entry, or DECLARE it notify-only in " \
            "RemediationValidator::NON_REMEDIATING_SIGNAL_KINDS / _ACTION_CATEGORIES (never infer)."
          when "executor_without_skill_row"
            "Add the #{subject} Ai::Skill catalog entry to system_skills_seed.rb (slug = executor class, dasherized, " \
            "system- prefix) so SkillBindingsReconciler can bind it."
          when "binding_agent_unknown"
            "Fix the binds_to target #{subject.inspect} — add it to SkillBindings::AGENT_ALIASES or seed the agent."
          when "lineage_edge_missing"
            "Attach the child under System Concierge through Ai::Agents::HierarchyWriter#attach! (materialised " \
            "under dev.governance_materialize; the boot reconcile writes it too)."
          when "delegation_policy_missing"
            "Write the declared delegation policy through HierarchyWriter#ensure_delegation_policy! (materialised " \
            "under dev.governance_materialize)."
          when "skill_binding_missing"
            "Create the Ai::AgentSkill row for #{gap['skill_slug']} on #{gap['agent_name']} (materialised under " \
            "dev.skill_refine; the boot reconcile writes it too)."
          when "policy_owner_undeclared"
            "Re-home the #{gap['action_category']} row onto #{gap['declared_owner']} (record the move in " \
            "PolicyReconciler::FORMER_OWNERS) or deactivate it — the reconciler never touches a row on an " \
            "undeclared agent."
          when "tool_family_unregistered"
            "Remove or correct #{gap['family'].inspect} in the agent's seeded tool_access.tool_families; the " \
            "ToolAllowlist matches a registry action by exact name or `<family>_` prefix."
          when "prompt_refinement"
            # SEAM, not a live lane: GovernanceGapSensor has no prompt-drift
            # detector, so no gap of this kind reaches here from the tick. The
            # arm serves a hand-built or future-detected gap so the refinement
            # takes the versioned path instead of an in-place prompt edit.
            "Record the refined prompt as an Ai::SkillVersion through Ai::SelfImprovement::SkillRefinementService " \
            "(materialised under dev.prompt_refine)."
          else
            gap["summary"].to_s
          end
        end

        def file_offer!(spec, gap, fingerprint)
          existing = open_offer(fingerprint)
          evidence = {
            "title" => spec[:title],
            "description" => spec[:description],
            "files" => spec[:files],
            "fingerprint" => fingerprint,
            "gap_kind" => spec[:kind],
            "subject" => spec[:subject],
            "severity" => spec[:severity],
            "gap" => gap.except("materialization", "_sensor"),
            "materialization" => gap["materialization"],
            "proposed_by" => PROPOSED_BY,
            "proposed_by_agent_id" => @agent&.id,
            "detections" => (existing&.evidence&.dig("detections").to_i + 1),
            "last_detected_at" => Time.current.iso8601
          }.compact
          attrs = {
            recommended_config: { "fix" => spec[:fix] },
            evidence: evidence,
            confidence_score: confidence_for(spec[:severity])
          }

          if existing
            existing.update!(attrs)
            [ existing, true ]
          else
            offer = ::Ai::ImprovementRecommendation.create!(
              attrs.merge(account: @account, recommendation_type: spec[:type],
                          target_type: "Account", target_id: @account.id, status: "pending", current_config: {})
            )
            [ offer, false ]
          end
        end

        # Same dedup rule as ImprovementTool#open_offer_for: pending, this
        # account, this target, this fingerprint. A dismissed or applied offer
        # does not absorb a gap that returns — that recurrence is news.
        def open_offer(fingerprint)
          ::Ai::ImprovementRecommendation
            .where(account: @account, status: "pending", target_type: "Account", target_id: @account.id)
            .where("evidence->>'fingerprint' = ?", fingerprint)
            .order(:created_at)
            .first
        end

        def confidence_for(severity)
          { "critical" => 0.95, "high" => 0.9, "medium" => 0.8, "low" => 0.7 }.fetch(severity.to_s, 0.75)
        end

        def materialize!(offer, gap, fingerprint)
          spec = gap["materialization"]
          return nil unless spec.is_a?(Hash) && spec["kind"].present?

          result = ::System::Governance::GapMaterializer
                     .new(account: @account, agent: @agent)
                     .call(kind: spec["kind"], params: spec.except("kind"), fingerprint: fingerprint, offer: offer)

          # The materializer closes the offer itself on an applied write (it is
          # the only path that runs on the approved replay too); a parked or
          # blocked one is recorded on the offer for the reviewer.
          unless result[:status] == "applied"
            offer.reload
            offer.update!(evidence: offer.evidence.merge(
              "materialization" => (offer.evidence["materialization"] || {}).merge(
                "status" => result[:status], "action_category" => result[:action_category],
                "deferred_operation_id" => result[:deferred_operation_id], "error" => result[:error]
              ).compact
            ))
          end

          result
        rescue StandardError => e
          ::Rails.logger.error("[GovernanceGapProposeExecutor] materialisation failed for #{fingerprint}: #{e.class}: #{e.message}")
          { status: "failed", error: e.message }
        end
      end
    end
  end
end
