# frozen_string_literal: true

module System
  module CveOps
    module Sensors
      # Detects the intersection of (a) PackageModuleLink with upstream version
      # drift and (b) an open CveExposure on the linked module's current
      # version. Emits `system.module_critical_upgrade_ready` signals so the
      # orchestration executor can prioritize these modules ahead of generic
      # drift.
      #
      # This is intentionally narrower than Fleet's PackageDriftSensor:
      #   - PackageDriftSensor emits for every drifted module (CVE or not)
      #     and boosts severity when CVE-flagged.
      #   - CriticalUpgradeAvailableSensor emits ONLY when both drift AND
      #     CVE exposure are present, with a payload pre-joined so the
      #     orchestrator doesn't have to re-query.
      #
      # Per the 2026-05-10 5-agent split, this lives in CVE Responder's
      # domain. Fleet's PackageDriftSensor remains unchanged and continues
      # to drive non-CVE refresh decisions.
      class CriticalUpgradeAvailableSensor < ::System::Fleet::Sensors::BaseSensor
        STALE_THRESHOLD = 24.hours

        def sense
          return [] unless defined?(::System::PackageModuleLink)
          return [] unless defined?(::System::CveExposure)

          cutoff = Time.current - STALE_THRESHOLD

          links = ::System::PackageModuleLink
            .joins(:node_module)
            .where(system_node_modules: { account_id: account.id })
            .where("system_package_module_links.last_synced_at < ?", cutoff)

          links.filter_map { |link| signal_for(link) }
        end

        private

        def signal_for(link)
          upstream = ::System::Package.live.find_by(
            package_repository_id: link.package_repository_id,
            name:                  link.package_name,
            architecture:          link.architecture
          )
          return nil unless upstream

          adapter = ::System::PackageAdapters.for(kind: link.package_repository.kind)
          return nil if adapter.compare_versions(upstream.version, link.package_version) <= 0

          cve_ids, severities = cve_exposure_summary_for(link.node_module_id)
          return nil if cve_ids.empty?

          severity_sym = severities.include?("critical") ? :critical : :high

          signal(
            kind: "system.module_critical_upgrade_ready",
            severity: severity_sym,
            payload: {
              package_module_link_id: link.id,
              node_module_id:         link.node_module_id,
              package_name:           link.package_name,
              architecture:           link.architecture,
              current_version:        link.package_version,
              upstream_version:       upstream.version,
              cve_ids:                cve_ids,
              cve_severities:         severities,
              affected_module_ids:    [ link.node_module_id ]
            },
            fingerprint: "crit_upgrade:#{link.id}:#{upstream.version}"
          )
        rescue StandardError => e
          Rails.logger.warn("[CriticalUpgradeAvailableSensor] link=#{link.id}: #{e.message}")
          nil
        end

        def cve_exposure_summary_for(node_module_id)
          rows = ::System::CveExposure
            .unresolved
            .joins(:cve, node_module_version: :node_module)
            .where(system_node_modules: { id: node_module_id })
            .where(system_cves: { severity: %w[critical high] })
            .pluck("system_cves.cve_id", "system_cves.severity")

          cve_ids = rows.map(&:first).uniq
          severities = rows.map(&:last).uniq
          [ cve_ids, severities ]
        end
      end
    end
  end
end
