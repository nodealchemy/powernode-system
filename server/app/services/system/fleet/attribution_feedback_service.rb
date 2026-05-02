# frozen_string_literal: true

module System
  module Fleet
    # Records operator confirm/reject of an AttributeFailureExecutor
    # candidate as an Ai::CompoundLearning. Future executor calls read
    # these learnings to boost confidence in similar candidate patterns.
    #
    # Closes the feedback loop:
    #   sensor → signal → AttributeFailureExecutor → operator confirms/rejects
    #   → AttributionFeedbackService → CompoundLearning → next call's score boost
    #
    # Reference: Golden Eclipse plan creative — attribution learning loop.
    class AttributionFeedbackService
      def initialize(account:)
        @account = account
      end

      def record!(instance_id:, candidate_module_id:, candidate_kind:, confirmed:, note: nil)
        return { ok: false, error: "instance_id required" } if instance_id.blank?
        return { ok: false, error: "candidate_module_id required" } if candidate_module_id.blank?

        instance = ::System::NodeInstance.joins(:node)
                     .where(system_nodes: { account_id: @account.id })
                     .find_by(id: instance_id)
        return { ok: false, error: "instance not in account" } unless instance

        mod = ::System::NodeModule.where(account: @account).find_by(id: candidate_module_id)
        return { ok: false, error: "module not in account" } unless mod

        learning = create_learning(instance: instance, mod: mod,
                                   candidate_kind: candidate_kind,
                                   confirmed: confirmed, note: note)

        # Emit a fleet event so the dashboard can show feedback was recorded
        # and so subsequent ticks don't redundantly attribute the same module.
        ::System::Fleet::EventBroadcaster.emit!(
          account: @account,
          kind: confirmed ? "system.attribution_confirmed" : "system.attribution_rejected",
          severity: :low,
          payload: {
            instance_id: instance.id,
            module_id: mod.id,
            candidate_kind: candidate_kind,
            note: note,
            learning_id: learning&.id
          },
          source: "attribution_feedback",
          node_instance_id: instance.id,
          node_module_id: mod.id
        )

        { ok: true, learning_id: learning&.id }
      rescue StandardError => e
        Rails.logger.error("[AttributionFeedbackService] #{e.class}: #{e.message}")
        { ok: false, error: e.message }
      end

      private

      def create_learning(instance:, mod:, candidate_kind:, confirmed:, note:)
        return nil unless defined?(::Ai::CompoundLearning)

        category = confirmed ? "discovery" : "failure_mode"
        title = if confirmed
                  "Module #{mod.name} confirmed cause of instance failure"
                else
                  "Module #{mod.name} rejected as cause of instance failure"
                end

        content = build_content(instance, mod, candidate_kind, confirmed, note)
        tags = ["fleet", "attribution", "module:#{mod.id}", "kind:#{candidate_kind}"]
        tags << (confirmed ? "outcome:confirmed" : "outcome:rejected")

        ::Ai::CompoundLearning.create!(
          account_id: @account.id,
          ai_agent_team_id: nil,
          title: title.truncate(120),
          content: content.truncate(2000),
          category: category,
          scope: "team",
          tags: tags,
          status: "active",
          confidence_score: confirmed ? 0.7 : 0.5,
          importance_score: confirmed ? 0.7 : 0.4
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn("[AttributionFeedbackService] learning invalid: #{e.message}")
        nil
      end

      def build_content(instance, mod, kind, confirmed, note)
        [
          "Operator attribution feedback.",
          "",
          "Instance: #{instance.id} (#{instance.name})",
          "Module:   #{mod.name} (#{mod.id})",
          "Candidate kind: #{kind}",
          "Outcome: #{confirmed ? 'CONFIRMED — module was the cause' : 'REJECTED — module was NOT the cause'}",
          note ? "Note: #{note}" : nil,
          "",
          "This learning is read by AttributeFailureExecutor on future calls",
          "to boost (confirmed) or downweight (rejected) similar candidates."
        ].compact.join("\n")
      end
    end
  end
end
