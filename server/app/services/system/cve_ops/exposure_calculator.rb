# frozen_string_literal: true

module System
  module CveOps
    # Compares a CVE's affected_packages against every NodeModuleVersion
    # in the account, recording matches as System::CveExposure rows.
    #
    # v0 matcher: name keyword overlap. M-D2-2.5 layers real CPE-based
    # matching once we have proper SBOM parsing on every NodeModuleVersion.
    #
    # Reference: Golden Eclipse plan M-D2-2.
    class ExposureCalculator
      Result = Struct.new(:ok?, :exposures_created, :exposures_updated, :error, keyword_init: true)

      def self.calculate!(cve:, account:)
        new.calculate!(cve: cve, account: account)
      end

      def calculate!(cve:, account:)
        raise ArgumentError, "cve required" unless cve.is_a?(::System::Cve)
        raise ArgumentError, "account required" unless account

        package_names = cve.normalized_affected_packages.map { |p| p["name"].to_s.downcase }.compact_blank

        exposures_created = 0
        exposures_updated = 0

        ::System::NodeModuleVersion
          .joins(node_module: :account)
          .where(accounts: { id: account.id })
          .find_each do |version|
            matches = match_for_version(version, package_names, cve)
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

        Result.new(ok?: true, exposures_created: exposures_created, exposures_updated: exposures_updated)
      rescue StandardError => e
        Rails.logger.error("[ExposureCalculator] #{e.class}: #{e.message}")
        Result.new(ok?: false, error: e.message, exposures_created: 0, exposures_updated: 0)
      end

      private

      # v0: keyword match against module name + repo name.
      # M-D2-2.5: use SBOM packages from the OCI artifact.
      def match_for_version(version, package_names, _cve)
        haystack = "#{version.node_module&.name} #{version.node_module&.gitea_repo_full_name}".downcase
        package_names.filter_map do |pname|
          next unless haystack.include?(pname)
          { package_name: pname, package_version: nil }
        end
      end
    end
  end
end
