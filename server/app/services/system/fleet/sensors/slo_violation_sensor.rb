# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # DORMANT (decided 2026-08-23, IMP-6355c5adc382): this is the tick
      # entry point into a dead chain. #sense calls
      # System::Slo::ScoreEvaluator.evaluate_all, which queries
      # System::Slo::Definition — and repo-wide the only code that ever
      # creates one is a spec, not this sensor or anything upstream of it.
      # So on every 60s fleet tick this sensor runs, finds zero definitions,
      # and returns `[]`; `system.slo_violation` can never actually fire.
      # Reachable but inert, kept intentionally, not deleted. Do NOT build a
      # Definition producer to revive it; the platform consolidated on
      # System::ProjectMetric as its one telemetry convention instead (cron →
      # SystemFleetReconcileJob → FleetAutonomyService.tick! →
      # collect_project_metrics! → ProjectMetricsCollector →
      # System::ProjectMetric → ProjectSloSensor → DecisionEngine) — see
      # Fleet::Sensors::ProjectSloSensor, the sensor that actually fires.
      # ProjectSloSensor reads System::ProjectMetric.recent_for_mission
      # (mission-scoped); it does NOT read FleetEvent at all. Only this
      # sensor's ScoreEvaluator was ever in the FleetEvent lane — do not
      # conflate the two. See
      # spec/services/system/slo/dormancy_guard_spec.rb for the ratchet.
      #
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
