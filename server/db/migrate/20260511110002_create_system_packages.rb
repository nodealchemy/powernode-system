# frozen_string_literal: true

class CreateSystemPackages < ActiveRecord::Migration[8.0]
  def change
    create_table :system_packages, id: :uuid do |t|
      t.references :package_repository, type: :uuid, null: false,
        foreign_key: { to_table: :system_package_repositories, on_delete: :cascade }

      t.string :name, null: false
      t.string :version, null: false
      t.string :architecture, null: false
      t.string :release_version          # rpm only ("1.fc40", etc.)
      t.string :section_or_group         # apt "Section" / rpm "Group"

      t.text   :description
      t.text   :summary
      t.bigint :installed_size_bytes
      t.bigint :download_size_bytes

      # Normalized dependency shape per field:
      #   [ [{name, op, version}, {name, op, version}], ... ]   # outer = AND, inner = OR (alternatives)
      t.jsonb :depends,      null: false, default: []
      t.jsonb :pre_depends,  null: false, default: []
      t.jsonb :recommends,   null: false, default: []
      t.jsonb :suggests,     null: false, default: []
      t.jsonb :conflicts,    null: false, default: []
      t.jsonb :provides,     null: false, default: []
      t.jsonb :replaces,     null: false, default: []
      t.jsonb :breaks,       null: false, default: []

      t.string :filename     # relative path in repo (e.g., "pool/main/n/nginx/nginx_1.24.0-1ubuntu1_amd64.deb")
      t.string :sha256
      t.string :sha512
      t.string :homepage
      t.string :license
      t.string :maintainer

      # Full parsed control fields (forward-compat for fields we don't promote to columns)
      t.jsonb :raw_metadata, null: false, default: {}

      # Soft delete when no longer present in upstream index (preserves PackageModuleLink history)
      t.datetime :obsoleted_at

      t.timestamps
    end

    add_index :system_packages,
      [:package_repository_id, :name, :architecture, :version],
      unique: true,
      name: "idx_pkg_repo_name_arch_ver"

    add_index :system_packages, :name
    add_index :system_packages, [:name, :architecture]
    add_index :system_packages, :obsoleted_at, where: "obsoleted_at IS NOT NULL"

    # Trigram + GIN indexes for search (uses pg_trgm extension which is already
    # enabled in this codebase per pgvector setup).
    enable_extension "pg_trgm" unless extension_enabled?("pg_trgm")
    add_index :system_packages, :name, using: :gin, opclass: :gin_trgm_ops,
      name: "idx_packages_name_trgm"
    add_index :system_packages, :description, using: :gin, opclass: :gin_trgm_ops,
      name: "idx_packages_description_trgm"

    # JSONB GIN for fast "who provides this name" / "what depends on this" queries
    add_index :system_packages, :provides, using: :gin, name: "idx_packages_provides_gin"
    add_index :system_packages, :depends,  using: :gin, name: "idx_packages_depends_gin"
  end
end
