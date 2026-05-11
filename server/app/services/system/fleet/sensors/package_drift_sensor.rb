# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects PackageModuleLink rows where the upstream apt/rpm package
      # version has bumped beyond what the local NodeModule currently
      # carries. Emits `system.package_drift_pressure` signals; severity
      # boosted to :high when the package is CVE-affected (cross-references
      # System::CveExposure via the linked NodeModule's current version).
      #
      # Fleet Autonomy's `package_module.refresh` policy consumes these
      # signals and proposes a refresh (auto-approved for CVE-flagged
      # packages, human-approval required otherwise).
      class PackageDriftSensor < BaseSensor
        # Don't fire for very fresh links — newly-materialized modules with
        # a refresh delta will just churn. Wait until 24h after last sync.
        STALE_THRESHOLD = 24.hours

        def sense
          cutoff = Time.current - STALE_THRESHOLD
          ::System::PackageModuleLink
            .joins(:node_module)
            .where(system_node_modules: { account_id: account.id })
            .where("system_package_module_links.last_synced_at < ?", cutoff)
            .find_each.filter_map { |link| drift_signal_for(link) }
        end

        private

        def drift_signal_for(link)
          upstream = ::System::Package.live.find_by(
            package_repository_id: link.package_repository_id,
            name:                  link.package_name,
            architecture:          link.architecture
          )
          return nil unless upstream

          adapter = ::System::PackageAdapters.for(kind: link.package_repository.kind)
          return nil if adapter.compare_versions(upstream.version, link.package_version) <= 0

          severity = cve_flagged?(link) ? :high : :medium

          signal(
            kind: "system.package_drift_pressure",
            severity: severity,
            payload: {
              package_module_link_id: link.id,
              node_module_id:         link.node_module_id,
              package_name:           link.package_name,
              current_version:        link.package_version,
              upstream_version:       upstream.version,
              architecture:           link.architecture,
              cve_flagged:            (severity == :high)
            },
            fingerprint: "pkg_drift:#{link.id}:#{upstream.version}"
          )
        rescue StandardError => e
          Rails.logger.warn("[PackageDriftSensor] error for link=#{link.id}: #{e.message}")
          nil
        end

        # Cross-references System::CveExposure rows touching this link's module.
        # Returns true if any CveExposure exists tied to the module's current
        # version. False if the platform doesn't have a CVE catalog active.
        def cve_flagged?(link)
          return false unless defined?(::System::CveExposure)

          ::System::CveExposure
            .joins(node_module_version: :node_module)
            .where(system_node_modules: { id: link.node_module_id })
            .exists?
        end
      end
    end
  end
end
