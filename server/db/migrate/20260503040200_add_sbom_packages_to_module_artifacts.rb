# frozen_string_literal: true

# Cache parsed SBOM package list on ModuleArtifact. The full SBOM blob lives
# in OCI as a referrer of `oci_ref` (path stored in `sbom_uri`); we materialize
# the parsed package list locally so CVE exposure calculation doesn't fetch
# from OCI per query.
#
# Schema:
#   sbom_packages_data — JSONB array of { name, version, ecosystem, purl, license }
#   sbom_packages_synced_at — last successful refresh timestamp
#   sbom_packages_count — denormalized for query convenience
#
# Reference: comprehensive stabilization sweep P4.
class AddSbomPackagesToModuleArtifacts < ActiveRecord::Migration[8.1]
  def change
    add_column :system_module_artifacts, :sbom_packages_data, :jsonb, default: []
    add_column :system_module_artifacts, :sbom_packages_synced_at, :datetime
    add_column :system_module_artifacts, :sbom_packages_count, :integer, default: 0, null: false

    add_index :system_module_artifacts, :sbom_packages_synced_at
    add_index :system_module_artifacts, :sbom_packages_count
  end
end
