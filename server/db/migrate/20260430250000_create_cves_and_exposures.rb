# frozen_string_literal: true

# Creates the CVE feed table + per-module-version exposure join.
# Reference: Golden Eclipse plan M-D2-2.
#
# system_cves rows are unique by cve_id (NVD canonical ID, e.g. CVE-2026-12345).
# system_cve_exposures join CVEs to NodeModuleVersions with state tracking.
class CreateCvesAndExposures < ActiveRecord::Migration[8.1]
  def up
    create_table :system_cves, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :cve_id, null: false
      t.string :severity, null: false # critical|high|medium|low|unknown
      t.text :summary
      t.jsonb :affected_packages, default: -> { "'[]'::jsonb" }, null: false
      t.string :reference_url
      t.datetime :published_at
      t.datetime :ingested_at, default: -> { "now()" }
      t.string :feed_source # "nvd" | "ghsa" | "manual"
      t.jsonb :metadata, default: -> { "'{}'::jsonb" }, null: false
      t.timestamps

      t.index :cve_id, unique: true
      t.index :severity
      t.index :published_at
      t.index :ingested_at
      t.index :affected_packages, using: :gin
    end

    create_table :system_cve_exposures, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :cve, null: false, foreign_key: { to_table: :system_cves }, type: :uuid
      t.references :node_module_version, null: false,
        foreign_key: { to_table: :system_node_module_versions }, type: :uuid
      t.string :package_name, null: false
      t.string :package_version
      t.string :state, null: false, default: "open" # open|remediating|resolved|wont_fix
      t.datetime :detected_at, default: -> { "now()" }, null: false
      t.datetime :resolved_at
      t.string :resolution_note
      t.jsonb :metadata, default: -> { "'{}'::jsonb" }, null: false
      t.timestamps

      t.index [:cve_id, :node_module_version_id, :package_name],
              unique: true, name: "ix_cve_exposures_unique"
      t.index :state
      t.index :detected_at
    end

    add_check_constraint :system_cves,
      "severity IN ('critical', 'high', 'medium', 'low', 'unknown')",
      name: "ck_cves_severity"
    add_check_constraint :system_cve_exposures,
      "state IN ('open', 'remediating', 'resolved', 'wont_fix')",
      name: "ck_cve_exposures_state"
  end

  def down
    drop_table :system_cve_exposures
    drop_table :system_cves
  end
end
