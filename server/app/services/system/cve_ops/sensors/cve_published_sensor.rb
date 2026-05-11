# frozen_string_literal: true

module System
  module CveOps
    module Sensors
      # Detects open `System::CveExposure` rows whose source CVE is critical
      # or high severity and emits one `system.cve_critical_published` signal
      # per CVE per tick. The signal payload enumerates every exposed module
      # so the orchestration executor can fan out remediation in a single
      # decision.
      #
      # Dedup at the engine level uses fingerprint `cve_pub:<cve_id>` with the
      # standard 600s TTL. Beyond that window the engine re-routes and the
      # orchestration executor's pending/recently-rejected ApprovalRequest
      # check absorbs the repeat without duplicate work.
      #
      # Lives in `System::CveOps::Sensors` (not `System::Fleet::Sensors`) so
      # the Fleet Autonomy tick's SENSORS constant doesn't sweep it up; the
      # CVE Responder owns this sensor exclusively via its own SENSORS list.
      class CvePublishedSensor < ::System::Fleet::Sensors::BaseSensor
        DETECTION_LOOKBACK = (ENV["CVE_RESPONDER_DETECTION_LOOKBACK_HOURS"] || 24).to_i.hours

        ELIGIBLE_SEVERITIES = %w[critical high].freeze

        def sense
          return [] unless defined?(::System::CveExposure)
          return [] unless defined?(::System::Cve)

          rows = ::System::CveExposure
            .joins(:cve, node_module_version: :node_module)
            .where(system_node_modules: { account_id: account.id })
            .where(state: "open")
            .where(system_cves: { severity: ELIGIBLE_SEVERITIES })
            .where("system_cve_exposures.detected_at > ?", DETECTION_LOOKBACK.ago)
            .preload(:cve, node_module_version: :node_module)
            .to_a

          rows.group_by(&:cve).map { |cve, exposures| signal_for(cve, exposures) }
        end

        private

        def signal_for(cve, exposures)
          module_ids = exposures.filter_map { |e| e.node_module_version&.node_module_id }.uniq
          package_names = exposures.map(&:package_name).compact.uniq
          severity_sym = cve.severity == "critical" ? :critical : :high

          signal(
            kind: "system.cve_critical_published",
            severity: severity_sym,
            payload: {
              cve_id: cve.cve_id,
              cve_severity: cve.severity,
              cve_summary: cve.summary.to_s.truncate(200),
              exposure_ids: exposures.map(&:id),
              affected_module_ids: module_ids,
              affected_packages: package_names,
              exposure_count: exposures.size
            },
            fingerprint: "cve_pub:#{cve.cve_id}"
          )
        end
      end
    end
  end
end
