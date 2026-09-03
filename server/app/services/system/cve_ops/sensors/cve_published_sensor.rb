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
      # standard 600s TTL. Beyond that window the engine re-routes the signal
      # and the orchestration re-runs: `open_operator_request?` covers only
      # the require_approval path, so under notify_and_proceed nothing absorbs
      # the repeat (see the orchestrator's header, IMP-9b8d774298d5).
      #
      # DETECTION WINDOW (IMP-60717919d4a0). This sensor selects only
      # exposures with `detected_at` inside #detection_lookback, and
      # `detected_at` is written once (CveExposure#record_match) and refreshed
      # on exactly ONE re-match: an sbom match confirming a row that had no
      # version evidence — a `suspected` row, or one this task's migration
      # resolved as a keyword false positive (IMP-7bba0413c36a). That
      # confirmation IS the detection, and re-enters this window deliberately;
      # nothing else re-stamps it. So an exposure left
      # `open` leaves this sensor's view a window after first detection
      # whether or not anything ever remediated it — the autonomy lane is a
      # fresh-detection lane by construction, not a standing alarm. What keeps
      # an aged, still-open exposure reachable by an operator is
      # System::CveOps::AgedExposureEscalator, which the CVE Responder tick
      # runs against the SAME window and which emits one durable
      # `cve_responder.exposure_aged_out` FleetEvent per CVE per window,
      # correlated to `cve_pub:<cve_id>`. Widening the window here widens both.
      #
      # The window is operator configuration, resolved per tick through
      # System::CveOps::TunableSetting: per-account
      # `Account#settings[ACCOUNT_DETECTION_LOOKBACK_KEY]`, then the
      # deployment-wide SiteSetting `DETECTION_LOOKBACK_SETTING_KEY`, then
      # DEFAULT_DETECTION_LOOKBACK_HOURS. That is the shape
      # ModulePromotionBacklogSensor#lag_seconds uses — NOT BaseSensor's
      # SensorConfig seam, which the CVE sensors are deliberately outside of
      # (see TunableSetting's header for why, and for what it does reuse from
      # that seam). It was previously an ENV read baked into a class constant
      # at boot.
      #
      # Lives in `System::CveOps::Sensors` (not `System::Fleet::Sensors`) so
      # the Fleet Autonomy tick's SENSORS constant doesn't sweep it up; the
      # CVE Responder owns this sensor exclusively via its own SENSORS list.
      class CvePublishedSensor < ::System::Fleet::Sensors::BaseSensor
        DEFAULT_DETECTION_LOOKBACK_HOURS = 24
        DETECTION_LOOKBACK_SETTING_KEY   = "system.cve_responder.detection_lookback_hours"
        ACCOUNT_DETECTION_LOOKBACK_KEY   = "cve_responder_detection_lookback_hours"

        ELIGIBLE_SEVERITIES = %w[critical high].freeze

        def sense
          return [] unless defined?(::System::CveExposure)
          return [] unless defined?(::System::Cve)

          # `state: "open"` only — `remediating` is the orchestrator's silence
          # and `suspected` (IMP-7bba0413c36a: a keyword-only match with no
          # version evidence) is not an exposure at all until an SBOM match
          # flips it to open.
          rows = ::System::CveExposure
            .joins(:cve, node_module_version: :node_module)
            .where(system_node_modules: { account_id: account.id })
            .where(state: "open")
            .where(system_cves: { severity: ELIGIBLE_SEVERITIES })
            .where("system_cve_exposures.detected_at > ?", detection_lookback.ago)
            .preload(:cve, node_module_version: :node_module)
            .to_a

          rows.group_by(&:cve).map { |cve, exposures| signal_for(cve, exposures) }
        end

        # Memoized for the life of ONE sensor instance (one tick), like
        # BaseSensor#threshold: a sense pass must not straddle a mid-tick
        # config change. Public so the CVE Responder tick can hand the SAME
        # resolved window to AgedExposureEscalator instead of resolving a
        # second one — the two lanes are complements of one window, and two
        # reads can leave a gap or an overlap between them.
        #
        # Fails to the constant, never to nil and never by raising, for any
        # value that is not a positive integer at every rung — `0` would read
        # as "never look at anything".
        def detection_lookback
          @detection_lookback ||= ::System::CveOps::TunableSetting.resolve(
            account: account,
            account_key: ACCOUNT_DETECTION_LOOKBACK_KEY,
            site_setting_key: DETECTION_LOOKBACK_SETTING_KEY,
            default: DEFAULT_DETECTION_LOOKBACK_HOURS
          ).hours
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
