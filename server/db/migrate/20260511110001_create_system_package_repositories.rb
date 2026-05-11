# frozen_string_literal: true

class CreateSystemPackageRepositories < ActiveRecord::Migration[8.0]
  def change
    create_table :system_package_repositories, id: :uuid do |t|
      # account_id NULL ⇔ shared (system-wide). NOT NULL ⇔ account-scoped.
      # Enforced via the check constraint at the bottom of this migration.
      t.references :account, type: :uuid, null: true, foreign_key: true
      t.references :node_platform, type: :uuid, null: true,
        foreign_key: { to_table: :system_node_platforms, on_delete: :nullify }
      t.references :created_by, type: :uuid, null: false,
        foreign_key: { to_table: :users, on_delete: :restrict }

      t.string :name, null: false
      t.text   :description
      t.string :kind, null: false             # "apt" | "rpm" | "dnf"
      t.string :visibility, null: false, default: "account"  # "account" | "shared"
      t.string :base_url, null: false
      t.text   :signing_key_armor             # cleartext PEM/ASCII-armored GPG public key
      t.string :vault_credential_path         # for private-repo signed-URL tokens via VaultCredential

      t.jsonb :architectures, null: false, default: ["amd64"]
      t.jsonb :apt_config, null: false, default: {}
      t.jsonb :rpm_config, null: false, default: {}

      t.integer :priority, null: false, default: 100
      t.boolean :enabled,  null: false, default: true

      t.string   :sync_status, null: false, default: "idle"  # idle|syncing|failed
      t.datetime :last_synced_at
      t.text     :last_sync_error
      t.integer  :package_count, null: false, default: 0

      t.timestamps
    end

    # Account-scoped uniqueness: one repo per (account, name) when account_id is set
    add_index :system_package_repositories, [:account_id, :name],
      unique: true,
      where: "account_id IS NOT NULL",
      name: "idx_pkgrepo_account_name_unique"

    # Shared-repo uniqueness: one shared repo per name globally
    add_index :system_package_repositories, :name,
      unique: true,
      where: "account_id IS NULL",
      name: "idx_pkgrepo_shared_name_unique"

    add_index :system_package_repositories, :visibility
    add_index :system_package_repositories, :enabled
    add_index :system_package_repositories, :sync_status

    add_check_constraint :system_package_repositories,
      "kind IN ('apt', 'rpm', 'dnf')",
      name: "chk_pkgrepo_kind"

    add_check_constraint :system_package_repositories,
      "visibility IN ('account', 'shared')",
      name: "chk_pkgrepo_visibility"

    add_check_constraint :system_package_repositories,
      "sync_status IN ('idle', 'syncing', 'failed')",
      name: "chk_pkgrepo_sync_status"

    # The load-bearing invariant: shared ⟺ account_id IS NULL
    add_check_constraint :system_package_repositories,
      "(visibility = 'shared' AND account_id IS NULL) OR " \
      "(visibility = 'account' AND account_id IS NOT NULL)",
      name: "chk_pkgrepo_visibility_account_consistency"
  end
end
