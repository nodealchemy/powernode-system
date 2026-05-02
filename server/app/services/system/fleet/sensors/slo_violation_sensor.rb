# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects SLO definitions whose evaluator score violates one or more
      # targets. Emits `system.slo_violation` signals — the DecisionEngine
      # binding for this kind routes to the rolling_module_upgrade skill
      # (escalation path: rebuild + roll forward) gated through
      # `system.module_assign` notify-and-proceed by default.
      #
      # Severity scales with violation count + worst-violated metric:
      #   1 metric off-target  → :medium
      #   2 metrics off-target → :high
      #   3+ metrics off-target → :critical
      class SloViolationSensor < BaseSensor
        def sense
          return [] unless defined?(::System::Slo::ScoreEvaluator)

          ::System::Slo::ScoreEvaluator.evaluate_all(account: account).filter_map do |score|
            next if score.within_target

            severity = case score.violations.size
                       when 1 then :medium
                       when 2 then :high
                       else :critical
                       end

            signal(
              kind: "system.slo_violation",
              severity: severity,
              payload: {
                module_id: score.definition.node_module_id,
                slo_name: score.definition.name,
                violations: score.violations,
                window: score.definition.window
              },
              fingerprint: "slo_violation:#{score.definition.id}"
            )
          end
        end
      end
    end
  end
end
