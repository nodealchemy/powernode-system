# frozen_string_literal: true

# M:N PackageRepository ↔ NodePlatform.
#
# The original create_system_package_repositories migration carried a
# single optional `node_platform_id` belongs_to. That under-modeled the
# real-world relationship — one repo (e.g. "Ubuntu noble main") is the
# package source for many platforms (24.04 minimal-arm64, 24.04 full-amd64,
# 24.04 minimal-amd64, …), and one platform may pull from many repos
# (base + security + third-party PPA).
#
# Clean break: drop the single FK, add a join table. Cross-account
# integrity is enforced at the model layer (PackageRepositoryPlatform)
# because the parent repo's account_id can be NULL (shared) — a hard
# DB-level "platform.account must equal repo.account" CHECK doesn't
# express the "shared repo links anywhere" branch cleanly.
class RepositoryPlatformManyToMany < ActiveRecord::Migration[8.0]
  def change
    remove_reference :system_package_repositories, :node_platform,
      type: :uuid, foreign_key: { to_table: :system_node_platforms }

    create_table :system_package_repository_platforms, id: :uuid do |t|
      t.references :package_repository, type: :uuid, null: false,
        foreign_key: { to_table: :system_package_repositories, on_delete: :cascade },
        index: { name: "idx_pkgrepo_platforms_repo" }
      t.references :node_platform, type: :uuid, null: false,
        foreign_key: { to_table: :system_node_platforms, on_delete: :cascade },
        index: { name: "idx_pkgrepo_platforms_platform" }
      t.timestamps
    end

    # Composite uniqueness — a (repo, platform) pair appears at most once.
    add_index :system_package_repository_platforms,
              [:package_repository_id, :node_platform_id],
              unique: true,
              name: "idx_pkgrepo_platforms_unique"
  end
end
