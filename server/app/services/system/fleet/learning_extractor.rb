# frozen_string_literal: true

module System
  module Fleet
    # Captures fleet decision outcomes as compound learnings (M8). After three
    # matching decisions accumulate, `auto_evolve_skill` promotes the pattern
    # to a reusable Skill — closing the self-improvement loop:
    #   sensor → signal → skill → decision → outcome → learning → skill mutation
    #
    # v0 records minimal payload (signal_kind, action_category, decision gate,
    # disruption_pct from the skill plan when available). M-D2-2 enriches with
    # actual remediation outcome (success/failure of the dispatched task).
    module LearningExtractor
      # Number of matching tagged learnings before triggering auto-evolution.
      # Plan M8: "After three matching learnings, auto_evolve_skill promotes
      # the pattern to a reusable Skill". Configurable via ENV for prod tuning.
      AUTO_EVOLVE_THRESHOLD = (ENV["FLEET_AUTO_EVOLVE_THRESHOLD"] || 3).to_i

      module_function

      def record_tick!(account:, decisions:)
        return if decisions.blank?

        learning_tool = ::Ai::Tools::LearningTool.new(account: account, agent: nil, user: nil) if defined?(::Ai::Tools::LearningTool)
        return record_dry(account: account, decisions: decisions) unless learning_tool

        bucketed = decisions.group_by { |d| [ d[:signal_kind], d[:gate], d[:decision] ] }
        bucketed.each do |key, group|
          signal_kind, gate, decision = key
          # We only learn from decisions that resulted in a *gate decision*
          # (proceed/pending/blocked). Skipped decisions (no binding) carry
          # no operational value yet.
          next if decision == :skipped

          submit_learning(learning_tool, account, signal_kind, gate, decision, group)
          maybe_auto_evolve!(account, signal_kind)
        end
      end

      def submit_learning(learning_tool, account, signal_kind, gate, decision, group)
        title = "Fleet #{signal_kind} → #{gate || decision}"
        content = build_content(signal_kind, gate, decision, group)
        category = decision == :pending ? "pattern" : "discovery"

        learning_tool.execute(params: {
          action: "create_learning",
          title: title.truncate(120),
          content: content.truncate(2000),
          category: category,
          tags: [ "fleet", "autonomy", signal_kind ].compact
        })
      rescue StandardError => e
        Rails.logger.warn("[FleetLearningExtractor] failed to record learning: #{e.message}")
      end

      # When AUTO_EVOLVE_THRESHOLD matching learnings accumulate for a single
      # signal_kind, trigger `auto_evolve_skill` once. The trigger is rate-
      # limited via the SkillMutationService's own internal logic (it skips
      # skills that have evolved recently), so calling it on every tick once
      # the threshold is met is safe.
      def maybe_auto_evolve!(account, signal_kind)
        return unless defined?(::Ai::CompoundLearning)

        count = ::Ai::CompoundLearning
                .where(account_id: account.id)
                .with_tag(signal_kind)
                .count
        return if count < AUTO_EVOLVE_THRESHOLD

        return unless defined?(::Ai::Tools::SelfImprovementTool)

        tool = ::Ai::Tools::SelfImprovementTool.new(account: account, agent: nil, user: nil)
        result = tool.execute(params: { action: "auto_evolve_skill" })

        if result.is_a?(Hash) && result[:success]
          Rails.logger.info(
            "[FleetLearningExtractor] auto_evolve_skill triggered: " \
            "signal_kind=#{signal_kind} matching_learnings=#{count} " \
            "skills_mutated=#{result.dig(:data, :skills_mutated) || 0}"
          )
        end
      rescue StandardError => e
        Rails.logger.warn("[FleetLearningExtractor] auto_evolve_skill failed: #{e.message}")
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
