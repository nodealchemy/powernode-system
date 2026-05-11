# frozen_string_literal: true

class CreateSystemStorageCredentials < ActiveRecord::Migration[8.0]
  def change
    create_table :system_storage_credentials, id: :uuid do |t|
      t.references :storage_assignment, type: :uuid, null: false,
        foreign_key: { to_table: :system_storage_assignments, on_delete: :cascade }
      t.references :node_instance, type: :uuid, null: false,
        foreign_key: { to_table: :system_node_instances, on_delete: :cascade }

      t.string  :kind, null: false
      t.string  :status, null: false, default: "issued"

      # VaultCredential trio (primary in Vault, DB fallback)
      t.string   :vault_path
      t.text     :encrypted_credentials
      t.datetime :migrated_to_vault_at
      t.string   :encryption_key_id

      t.datetime :expires_at
      t.datetime :last_rotated_at
      t.jsonb    :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :system_storage_credentials,
      [:storage_assignment_id, :status],
      name: "idx_storage_credentials_on_assignment_status"

    add_check_constraint :system_storage_credentials,
      "kind IN ('peer_ip_acl', 'cifs_user_pass', 'sts_token', 'tls_cert', 'webdav_basic')",
      name: "system_storage_credentials_kind_check"
    add_check_constraint :system_storage_credentials,
      "status IN ('issued', 'active', 'rotating', 'revoked', 'expired', 'failed')",
      name: "system_storage_credentials_status_check"
  end
end
