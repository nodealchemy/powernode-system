# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects PackageModuleLink rows where the upstream apt/rpm package
      # version has bumped beyond what the local NodeModule currently
      # carries. Emits `system.package_drift_pressure` signals; severity
      # boosted to :high when the package is CVE-affected (cross-references
      # the module's unresolved, version-confirmed System::CveExposure rows).
      #
      # WHERE THE SIGNAL ACTUALLY GOES (re-verified 2026-09-03 for
      # IMP-9f69531f042d — the previous wording here named a
      # `package_module.refresh` policy that NOTHING routes to; that category
      # is permitted and dedup-keyed in FleetAutonomyService but no signal
      # binds to it): DecisionEngine::SIGNAL_BINDINGS routes
      # `system.package_drift_pressure` to action_category
      # `system.package_repository.sync`, seeded `auto_approve` in
      # Governance::PolicyDeclarations, and REMEDIATION_APPLIERS actuates it
      # with DecisionEngine#sync_package_repository — a
      # PackageRepositorySyncService.enqueue!, i.e. a repository METADATA
      # refresh, not a module refresh.
      #
      # Severity is NOT an input to that gate: #gate_action! takes
      # action_category/metadata/force_policy/advisory, and force_policy_for
      # returns nil for every kind but system.template_closure_drift — so a
      # :medium drift signal and a :high one take the same auto-approved path.
      # What the boost below buys is the operator-facing severity on the
      # signal record (and the `cve_flagged` payload flag), not a different
      # approval outcome.
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
              # Dedup key for the system.package_repository.sync gate
              package_repository_id:  link.package_repository_id,
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
        # True only for an UNRESOLVED (open / remediating) row whose match is
        # VERSION-CONFIRMED (match_method sbom) — IMP-9f69531f042d. A
        # `suspected` row is a keyword name-overlap with no version evidence,
        # a resolved or wont_fix row carries a decision already, and a keyword
        # row is unconfirmed in every state; none of those is evidence that
        # THIS module's installed version is affected, so none of them may
        # label the drift signal CVE-driven. False if the platform doesn't
        # have a CVE catalog active.
        #
        # This is the CveResponseExecutor bar (unresolved + version_confirmed),
        # and it is STRICTER than the rest of the CVE lanes:
        # CriticalUpgradeAvailableSensor and the remediation orchestrator read
        # `.unresolved` alone, AgedExposureEscalator keys on state: "open".
        # The divergent case is a `remediating` keyword row — acted on there,
        # not boosted here.
        def cve_flagged?(link)
          return false unless defined?(::System::CveExposure)

          ::System::CveExposure
            .unresolved
            .version_confirmed
            .joins(node_module_version: :node_module)
            .where(system_node_modules: { id: link.node_module_id })
            .exists?
        end
      end
    end
  end
end
