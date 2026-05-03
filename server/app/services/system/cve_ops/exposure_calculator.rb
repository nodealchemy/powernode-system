# frozen_string_literal: true

module System
  module CveOps
    # Compares a CVE's affected_packages against every NodeModuleVersion
    # in the account, recording matches as System::CveExposure rows.
    #
    # **Matcher upgrade (P4)**: when the version's ModuleArtifact has cached
    # SBOM packages (`sbom_packages_count > 0`), uses ecosystem-aware
    # version-range matching via System::CveOps::VersionMatcher. Falls back
    # to the v0 keyword stub for artifacts without an ingested SBOM (e.g.,
    # legacy / pre-SBOM-pipeline modules).
    #
    # Reference: Golden Eclipse plan M-D2-2; comprehensive stabilization
    # sweep P4.
    class ExposureCalculator
      Result = Struct.new(:ok?, :exposures_created, :exposures_updated,
                          :sbom_match_count, :keyword_fallback_count,
                          :error, keyword_init: true)

      def self.calculate!(cve:, account:)
        new.calculate!(cve: cve, account: account)
      end

      def calculate!(cve:, account:)
        raise ArgumentError, "cve required" unless cve.is_a?(::System::Cve)
        raise ArgumentError, "account required" unless account

        affected = cve.normalized_affected_packages
        package_names = affected.map { |p| p["name"].to_s.downcase }.compact_blank

        exposures_created = 0
        exposures_updated = 0
        sbom_match_count = 0
        keyword_fallback_count = 0

        ::System::NodeModuleVersion
          .joins(node_module: :account)
          .where(accounts: { id: account.id })
          .includes(:module_artifacts)
          .find_each do |version|
            matches, source = match_for_version(version, affected, package_names)
            sbom_match_count += matches.size if source == :sbom
            keyword_fallback_count += matches.size if source == :keyword

            matches.each do |match|
              row = ::System::CveExposure.find_or_initialize_by(
                cve: cve,
                node_module_version: version,
                package_name: match[:package_name]
              )
              row.assign_attributes(
                package_version: match[:package_version],
                state: row.state.presence || "open",
                detected_at: row.detected_at || Time.current
              )
              if row.new_record?
                row.save!
                exposures_created += 1
              elsif row.changed?
                row.save!
                exposures_updated += 1
              end
            end
        end

        Result.new(
          ok?: true,
          exposures_created: exposures_created,
          exposures_updated: exposures_updated,
          sbom_match_count: sbom_match_count,
          keyword_fallback_count: keyword_fallback_count
        )
      rescue StandardError => e
        Rails.logger.error("[ExposureCalculator] #{e.class}: #{e.message}")
        Result.new(ok?: false, error: e.message, exposures_created: 0, exposures_updated: 0,
                   sbom_match_count: 0, keyword_fallback_count: 0)
      end

      private

      # Returns [matches, source] where source is :sbom or :keyword.
      # SBOM matching prefers any artifact for this version that has an
      # ingested SBOM. If none has one, falls back to keyword overlap on
      # module name + repo (v0 behavior).
      def match_for_version(version, affected_packages, package_names)
        sbom_artifact = version.module_artifacts.detect(&:sbom_packages?)

        if sbom_artifact
          matches = match_via_sbom(sbom_artifact, affected_packages)
          return [matches, :sbom]
        end

        [match_via_keywords(version, package_names), :keyword]
      end

      # Real matcher: cross every CVE entry against every SBOM package,
      # using VersionMatcher for ecosystem-aware version-range comparison.
      def match_via_sbom(artifact, affected_packages)
        sbom_pkgs = artifact.sbom_packages

        affected_packages.flat_map do |entry|
          target_name = entry["name"].to_s.downcase
          target_constraint = entry["version"].to_s
          target_ecosystem = entry["ecosystem"].to_s.downcase

          sbom_pkgs.filter_map do |pkg|
            pkg_name = pkg["name"].to_s.downcase
            next unless pkg_name == target_name || pkg_name.end_with?("/#{target_name}")

            ecosystem = pkg["ecosystem"].to_s.downcase
            ecosystem = target_ecosystem if ecosystem.empty?
            ecosystem = "generic" if ecosystem.empty?

            next unless ::System::CveOps::VersionMatcher.vulnerable?(
              version: pkg["version"], constraint: target_constraint, ecosystem: ecosystem
            )

            { package_name: pkg["name"].to_s, package_version: pkg["version"].to_s }
          end
        end
      end

      # v0 fallback: name keyword overlap against module name + repo. No
      # version-range awareness — flags ANY version of the named package.
      # Acceptable as a safety net but generates false positives.
      def match_via_keywords(version, package_names)
        haystack = "#{version.node_module&.name} #{version.node_module&.gitea_repo_full_name}".downcase
        package_names.filter_map do |pname|
          next unless haystack.include?(pname)
          { package_name: pname, package_version: nil }
        end
      end
    end
  end
end
