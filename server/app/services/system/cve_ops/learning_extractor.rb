# frozen_string_literal: true

module System
  module CveOps
    # CVE-flavored compound learning extractor. Mirrors Fleet's
    # `System::Fleet::LearningExtractor` shape so the two domains record
    # comparable patterns into the global learnings store, distinguished
    # only by the tag prefix ("cve_responder" vs "fleet").
    #
    # Why a separate extractor: the title carries the domain ("CVE
    # signal_kind → gate") and the tag list seeds auto_evolve_skill's
    # cluster query. Sharing Fleet's extractor would conflate the two
    # domains' learning clusters and degrade auto-evolution quality.
    module LearningExtractor
      AUTO_EVOLVE_THRESHOLD = (ENV["CVE_RESPONDER_AUTO_EVOLVE_THRESHOLD"] || 3).to_i

      module_function

      def record_tick!(account:, decisions:)
        return if decisions.blank?

        learning_tool = ::Ai::Tools::LearningTool.new(account: account, agent: nil, user: nil) if defined?(::Ai::Tools::LearningTool)
        return record_dry(account: account, decisions: decisions) unless learning_tool

        bucketed = decisions.group_by { |d| [ d[:signal_kind], d[:gate], d[:decision] ] }
        bucketed.each do |key, group|
          signal_kind, gate, decision = key
          next if decision == :skipped

          submit_learning(learning_tool, account, signal_kind, gate, decision, group)
          maybe_auto_evolve!(account, signal_kind)
        end
      end

      def submit_learning(learning_tool, account, signal_kind, gate, decision, group)
        title = "CVE #{signal_kind} → #{gate || decision}"
        content = build_content(signal_kind, gate, decision, group)
        category = decision == :pending ? "pattern" : "discovery"

        learning_tool.execute(params: {
          action: "create_learning",
          title: title.truncate(120),
          content: content.truncate(2000),
          category: category,
          tags: [ "cve_responder", "autonomy", signal_kind ].compact
        })
      rescue StandardError => e
        Rails.logger.warn("[CveLearningExtractor] failed to record learning: #{e.message}")
      end

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
            "[CveLearningExtractor] auto_evolve_skill triggered: " \
            "signal_kind=#{signal_kind} matching_learnings=#{count} " \
            "skills_mutated=#{result.dig(:data, :skills_mutated) || 0}"
          )
        end
      rescue StandardError => e
        Rails.logger.warn("[CveLearningExtractor] auto_evolve_skill failed: #{e.message}")
      end

      def build_content(signal_kind, gate, decision, group)
        sample = group.first
        cve_id = sample.dig(:skill_result, :data, :cve_id) || sample.dig(:skill_result, :data, "cve_id")
        risk = sample.dig(:skill_result, :data, :triage, :risk_score) ||
               sample.dig(:skill_result, :data, "triage", "risk_score")
        instance_count = group.count

        [
          "CVE Responder decision pattern observed during reconcile tick.",
          "",
          "Signal kind: #{signal_kind}",
          "Decision gate: #{gate || 'n/a'}",
          "Decision: #{decision}",
          "Occurrences this tick: #{instance_count}",
          cve_id ? "Sample CVE: #{cve_id}" : nil,
          risk ? "Sample risk_score: #{risk}" : nil,
          "",
          "Action category: #{sample[:action_category]}"
        ].compact.join("\n")
      end

      def record_dry(account:, decisions:)
        Rails.logger.info(
          "[CveLearningExtractor] dry record: " \
          "account=#{account.id} decisions=#{decisions.size}"
        )
      end
    end
  end
end
