# frozen_string_literal: true

module System
  module Fleet
    # Captures fleet decision outcomes as compound learnings (M8).
    #
    # It used to call SelfImprovementTool's auto_evolve_skill once three
    # learnings matched a signal kind. That call passed no user and no agent,
    # so the tool refused it (permission denied: ai.skills.update) on every
    # run, and it logged only on success, so the refusal never surfaced. It
    # was deleted rather than repaired: skill evolution already has a gated
    # door (the auto_evolve_skill MCP verb, dev.skill_refine), and a
    # reconciler that silently cannot act is worse than none.
    #
    # v0 records minimal payload (signal_kind, action_category, decision gate,
    # disruption_pct from the skill plan when available). M-D2-2 enriches with
    # actual remediation outcome (success/failure of the dispatched task).
    module LearningExtractor
      # Calibrated importance by category, mirroring the ralph-loop creation
      # seam (inc7): reconcile-tick decision patterns seed modest and earn
      # ranking through reuse (effective_importance) rather than the 0.5
      # tool default.
      IMPORTANCE_BY_CATEGORY = { "pattern" => 0.45, "discovery" => 0.35 }.freeze
      DEFAULT_IMPORTANCE = 0.35

      # IMP-3c9a6dc8f0a9 — kill switch for this producer (one learning per
      # fleet signal kind per tick, #submit_learning below). SiteSetting
      # (core model, read directly here — extension may reference core; no
      # core->extension dependency is introduced by this file reading a core
      # model).
      #
      # DEFAULTS TO ON, and the garbage-value polarity is INVERTED from
      # Ai::Learning::EvaluationService.enabled? — same reasoning as the two
      # sibling switches in Ai::Memory::SharedKnowledgeService and
      # Ai::Learning::CompoundLearningService (core): OFF is the dangerous
      # direction here (silently stops the platform learning from fleet
      # ticks), so a garbage value fails toward ON, not OFF. See either
      # sibling's constant comment for the full reasoning — restated at each
      # of the three sites deliberately, so whoever copies this pattern into
      # a fourth producer sees the warning at the site they're editing.
      FLEET_TICK_RECORDING_ENABLED_SETTING = "ai.knowledge_purge.fleet_tick_recording_enabled"

      # IMP-3c9a6dc8f0a9 review round (blocker 4) — reads SiteSetting#value
      # directly rather than through ::SiteSetting.get, whose per-
      # setting_type cast destroys the "this was garbage" signal for a
      # "boolean"-typed row before we ever see it (a typo collapses
      # straight to Ruby `false`, indistinguishable from a deliberate
      # false, so the fail-toward-ON parsing below never actually runs on
      # it). Same fix as the two core sibling switches — see either's
      # identical comment (Ai::Memory::SharedKnowledgeService.
      # import_from_learnings_enabled?, Ai::Learning::CompoundLearningService.
      # promote_cross_team_enabled?) for the full reasoning.
      #
      # IMP-3c9a6dc8f0a9 review round — REGRESSION FIX: accepts "1"/"yes"/
      # "0"/"no"/"off" too, a superset of what ::SiteSetting.get's own cast
      # already accepted — see SharedKnowledgeService's identical comment
      # for the full trace.
      def self.fleet_tick_recording_enabled?
        setting = ::SiteSetting.find_by(key: FLEET_TICK_RECORDING_ENABLED_SETTING)
        return true if setting.nil?

        case setting.value.to_s.strip.downcase
        when "true", "1", "yes" then true
        when "false", "0", "no", "off" then false
        else
          Rails.logger.warn(
            "[FleetLearningExtractor] #{FLEET_TICK_RECORDING_ENABLED_SETTING}=#{setting.value.inspect} is not " \
            "true/false; treating it as ON — OFF is the dangerous direction for this switch " \
            "(silently stops fleet-tick learning), so a garbage value fails toward ON, not OFF"
          )
          true
        end
      end

      module_function

      def record_tick!(account:, decisions:)
        return if decisions.blank?

        unless fleet_tick_recording_enabled?
          Rails.logger.info(
            "[FleetLearningExtractor] Recording skipped — kill switch " \
            "#{FLEET_TICK_RECORDING_ENABLED_SETTING} is OFF"
          )
          return
        end

        # `internal: true` is REQUIRED, not decorative. LearningTool gained a
        # per-action permission gate (G4): create_learning now demands
        # ai.analytics.manage, and this reconciler runs with no user at all. A
        # nil user does NOT imply internal — an MCP instance principal also
        # arrives with none — so without the explicit flag every tick would be
        # refused and the loop would silently stop learning.
        if defined?(::Ai::Tools::LearningTool)
          learning_tool = ::Ai::Tools::LearningTool.new(account: account, agent: nil, user: nil, internal: true,
                                                        call_origin: ::Ai::Tools::CallOrigin::SYSTEM_SERVICE)
        end
        return record_dry(account: account, decisions: decisions) unless learning_tool

        bucketed = decisions.group_by { |d| [ d[:signal_kind], d[:gate], d[:decision] ] }
        bucketed.each do |key, group|
          signal_kind, gate, decision = key
          # We only learn from decisions that resulted in a *gate decision*
          # (proceed/pending/blocked). Skipped decisions (no binding) carry
          # no operational value yet.
          next if decision == :skipped
          # F3-12 — zero-information buckets: deduped decisions (29k/day
          # live) and bare not_permitted blocks teach nothing; recording
          # them buried the real patterns (30% of the KB was these rows).
          # Policy blocks (decision :blocked with a gate) ARE still learned.
          next if decision == :deduped
          next if decision == :blocked && group.all? { |d| d[:reason].to_s == "not_permitted" }

          submit_learning(learning_tool, account, signal_kind, gate, decision, group)
        end
      end

      # F3-12 one-time cleanup for rows created before the skip/reinforce
      # logic existed: deletes zero-information buckets outright and
      # collapses duplicate titles onto the OLDEST row, folding the
      # duplicate count into its access_count so reinforcement history
      # isn't lost. Invoked via `rails system:fleet:consolidate_learnings`.
      def consolidate_legacy_rows!
        return { deleted_zero_info: 0, deleted_duplicates: 0 } unless defined?(::Ai::CompoundLearning)

        zero_info = ::Ai::CompoundLearning
                    .where("title LIKE ? OR title LIKE ?", "Fleet % → deduped", "Fleet % → blocked")
        deleted_zero_info = zero_info.delete_all

        deleted_duplicates = 0
        ::Ai::CompoundLearning
          .where("title LIKE ?", "Fleet %")
          .group(:account_id, :title)
          .having("COUNT(*) > 1")
          .count
          .each_key do |(account_id, title)|
            rows = ::Ai::CompoundLearning.where(account_id: account_id, title: title).order(:created_at)
            keeper = rows.first
            extras = rows.where.not(id: keeper.id)
            n = extras.delete_all
            next if n.zero?

            keeper.update_columns(access_count: keeper.access_count.to_i + n)
            deleted_duplicates += n
          end

        { deleted_zero_info: deleted_zero_info, deleted_duplicates: deleted_duplicates }
      end

      def submit_learning(learning_tool, account, signal_kind, gate, decision, group)
        title = "Fleet #{signal_kind} → #{gate || decision}".truncate(120)
        content = build_content(signal_kind, gate, decision, group)
        category = decision == :pending ? "pattern" : "discovery"

        # Idempotent reinforcement. These decision-pattern learnings recur on
        # every 60s reconcile tick with a deterministic title; creating a fresh
        # row each time floods the knowledge base (the 2026-06-09 audit found
        # 5,249 duplicates — 30% of the KB, finding F3-12). Reinforce the
        # existing pattern instead — that IS the intended "compound" behavior —
        # and only create the row on first occurrence.
        if defined?(::Ai::CompoundLearning)
          existing = ::Ai::CompoundLearning.where(account_id: account.id, title: title).first
          if existing
            existing.record_access!
            return
          end
        end

        learning_tool.execute(params: {
          action: "create_learning",
          title: title,
          content: content.truncate(2000),
          category: category,
          importance_score: IMPORTANCE_BY_CATEGORY.fetch(category, DEFAULT_IMPORTANCE),
          tags: [ "fleet", "autonomy", signal_kind ].compact
        })
      rescue StandardError => e
        Rails.logger.warn("[FleetLearningExtractor] failed to record learning: #{e.message}")
      end

      def build_content(signal_kind, gate, decision, group)
        sample = group.first
        plan_disruption = sample.dig(:skill_result, :data, :disruption_pct)
        instance_count = group.count

        [
          "Fleet decision pattern observed during reconcile tick.",
          "",
          "Signal kind: #{signal_kind}",
          "Decision gate: #{gate || 'n/a'}",
          "Decision: #{decision}",
          "Occurrences this tick: #{instance_count}",
          plan_disruption ? "Sample disruption_pct: #{plan_disruption}" : nil,
          "",
          "Action category: #{sample[:action_category]}"
        ].compact.join("\n")
      end

      # Dry-record path when LearningTool is unavailable in the runtime
      # (test envs that stub it out, etc.). Logs a structured line so test
      # harnesses can assert on extraction without DB churn.
      def record_dry(account:, decisions:)
        Rails.logger.info(
          "[FleetLearningExtractor] dry record: " \
          "account=#{account.id} decisions=#{decisions.size}"
        )
      end
    end
  end
end
