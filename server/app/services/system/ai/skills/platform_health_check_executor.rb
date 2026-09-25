# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill: the platform's COMPOSITE health answer.
      #
      # IMP-80a353489ba4 (operator ruling 2026-09-13, re-affirmed on release
      # 2026-09-18). System::Ai::Skills::PlatformMaintenanceExecutor used to
      # carry this as its fourth action, bound — like cert_status, cert_rotate
      # and drift_check — to "concierge". That made the platform's composite
      # health answer a side door on the concierge's skill list rather than a
      # duty anyone owned: System::Platform::ScheduledHealthCheckService
      # credits whichever agent PlatformMaintenanceExecutor is bound to
      # (resolved through SkillBindings, never hardcoded), and the concierge
      # is not who "watches the platform" — platform-health-monitor is. This
      # class is health_check split out with its own binding, so the sweep
      # attributes to the right owner and the concierge's skill list stops
      # implying it does composite health monitoring.
      #
      # cert_status / cert_rotate / drift_check STAY on
      # PlatformMaintenanceExecutor — routine maintenance, not the composite
      # health answer, and there is no reason to move them.
      #
      # Delegated whole to System::Platform::CompositeHealthProbe. Every
      # subsystem it declares gets its own entry with its own status, and a
      # subsystem that could not be observed reports `not_measured` rather
      # than "ok". See that class for the oracle rule and ranking; nothing
      # here re-implements or approximates a subsystem check.
      #
      # CARRIED FROM THE OLD FILE, still true here: this class does not
      # "mirror" a PlatformHealthController. No class of that name exists
      # in either repository. The comment pointed, inexactly, at the Compute
      # platform health dashboard's endpoint — a separate surface that became
      # an adapter over CompositeHealthProbe and was deleted with its panel
      # (fc-47); platform subsystem health is on /app/status.
      class PlatformHealthCheckExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "platform_health_check",
          description: "COMPOSITE platform health snapshot — the Rails API, worker, Sidekiq, Redis, PostgreSQL, the reverse proxy, the MCP endpoint, fleet tick liveness, provider egress and fleet error/silent counts, delegated whole to System::Platform::CompositeHealthProbe. Every subsystem gets its own entry; a subsystem that could not be observed reports not_measured, never ok. Use this skill when the operator asks whether the platform itself is healthy, degraded or down.",
          category: "devops",
          invocation_mode: "one_shot",
          inputs: {},
          outputs: {
            action: :string,
            data: :object,
            recommendations: [ :string ]
          }
        )

        binds_to "platform_health_monitor"

        protected

        def perform(**_args)
          probe = ::System::Platform::CompositeHealthProbe.new(
            account: @account, source: "platform_health_check.health_check"
          )
          result = probe.call_and_persist!

          success(
            action: "health_check",
            data: result,
            recommendations: health_recommendations(result)
          )
        end

        private

        # Recommendations name the SPECIFIC subsystems, and they never claim
        # everything is fine while something went unobserved — a run carrying
        # `not_measured` gets told what it could not see, not reassurance.
        def health_recommendations(result)
          recs = []

          if result[:down].any?
            recs << "DOWN: #{result[:down].join(', ')} — observed failing; investigate before anything else."
          end
          if result[:degraded].any?
            recs << "DEGRADED: #{result[:degraded].join(', ')}."
          end
          if result[:not_measured].any?
            recs << "NOT MEASURED: #{result[:not_measured].join(', ')} — these were not observed and are " \
                    "NOT known to be healthy. Configure or reach them before treating this run as complete."
          end

          fleet = result.dig(:subsystems, :fleet_instances) || {}
          if fleet[:error_count].to_i.positive?
            recs << "#{fleet[:error_count]} node instance(s) in status=error — call platform_resilience " \
                    "with action=failover_check for the per-instance detail."
          end

          recs << "All subsystems observed healthy." if result[:overall] == "ok"
          recs
        end
      end
    end
  end
end
