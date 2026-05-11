# frozen_string_literal: true

class CreateSystemPackageModuleLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :system_package_module_links, id: :uuid do |t|
      t.references :node_module, type: :uuid, null: false,
        foreign_key: { to_table: :system_node_modules, on_delete: :cascade },
        index: { unique: true }
      t.references :package_repository, type: :uuid, null: false,
        foreign_key: { to_table: :system_package_repositories, on_delete: :restrict }

      t.string :package_name, null: false
      t.string :package_version, null: false
      t.string :architecture, null: false

      # "manual" → operator authored the module by hand
      # "package_query" → file_spec discovered from dpkg -L / rpm -ql at build time
      t.string :file_spec_source, null: false, default: "package_query"

      # Audit trail for `a | b` alternatives resolved by PackageDependencyResolver.
      # Shape: { "libc6 | musl" => "libc6" }
      t.jsonb :alternatives_chosen, null: false, default: {}

      # Persisted recommends opt-ins from materialize-time UI.
      # Replayed by SystemPackageModuleRefreshJob to keep refreshes deterministic.
      # Shape: ["ssl-cert", "iproute2"]
      t.jsonb :recommends_chosen, null: false, default: []

      # `true` for transitive deps (libc6, libssl3, …) — these are hidden by default.
      # `false` for the user-requested top-level package (nginx, postgresql-16, …).
      t.boolean :auto_generated, null: false, default: true

      t.datetime :last_synced_at

      t.timestamps
    end

    # NOT unique on (repo, pkg, arch): two accounts may each materialize "nginx"
    # from the same shared repo into separate NodeModule rows. Per-account
    # uniqueness comes from NodeModule.name uniqueness (scoped to account_id).
    add_index :system_package_module_links,
      [:package_repository_id, :package_name, :architecture],
      name: "idx_pkg_module_link_repo_pkg_arch"

    add_check_constraint :system_package_module_links,
      "file_spec_source IN ('manual', 'package_query')",
      name: "chk_pkgmodlink_file_spec_source"
  end
end
