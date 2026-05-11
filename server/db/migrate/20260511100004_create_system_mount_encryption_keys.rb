# frozen_string_literal: true

class CreateSystemMountEncryptionKeys < ActiveRecord::Migration[8.0]
  def change
    create_table :system_mount_encryption_keys, id: :uuid do |t|
      t.references :storage_assignment, type: :uuid, null: false,
        foreign_key: { to_table: :system_storage_assignments, on_delete: :cascade }
      t.references :node_instance, type: :uuid, null: true,
        foreign_key: { to_table: :system_node_instances, on_delete: :nullify }
      # node_instance null = mount-wide key (e.g. fscrypt). Non-null = per-instance slot (LUKS).

      t.string :algorithm, null: false

      # VaultCredential trio
      t.string   :vault_path
      t.text     :encrypted_credentials
      t.datetime :migrated_to_vault_at
      t.string   :encryption_key_id

      t.boolean  :escrowed, null: false, default: true
      t.datetime :revoked_at
      t.jsonb    :metadata, null: false, default: {}

      t.timestamps
    end

    add_check_constraint :system_mount_encryption_keys,
      "algorithm IN ('aes-xts-plain64', 'aes-256-gcm', 'fscrypt-v2')",
      name: "system_mount_encryption_keys_algorithm_check"
  end
end
