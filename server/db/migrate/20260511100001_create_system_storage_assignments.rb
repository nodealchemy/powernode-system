# frozen_string_literal: true

class CreateSystemStorageAssignments < ActiveRecord::Migration[8.0]
  def change
    create_table :system_storage_assignments, id: :uuid do |t|
      t.references :account, type: :uuid, null: false, foreign_key: true
      t.uuid :file_storage_id, null: false  # soft FK — file_management_storages in platform table set
      t.references :node_instance, type: :uuid, null: false,
        foreign_key: { to_table: :system_node_instances, on_delete: :cascade }
      t.references :sdwan_network, type: :uuid, null: true,
        foreign_key: { to_table: :sdwan_networks, on_delete: :nullify }
      t.references :sdwan_virtual_ip, type: :uuid, null: true,
        foreign_key: { to_table: :sdwan_virtual_ips, on_delete: :nullify }

      t.string  :mount_path, null: false
      t.jsonb   :mount_options, null: false, default: {}
      t.boolean :read_only, null: false, default: false
      t.boolean :enabled, null: false, default: true
      t.boolean :auto_mount, null: false, default: true
      t.string  :status, null: false, default: "pending"
      t.string  :encryption_mode, null: false, default: "inherit"

      t.datetime :last_mounted_at
      t.datetime :last_status_at
      t.text     :error_message

      t.timestamps
    end

    add_index :system_storage_assignments,
      :file_storage_id,
      name: "idx_storage_assignments_on_file_storage_id"
    add_index :system_storage_assignments,
      [:file_storage_id, :node_instance_id],
      unique: true,
      name: "idx_storage_assignments_unique_storage_instance"
    add_index :system_storage_assignments,
      [:node_instance_id, :mount_path],
      unique: true,
      name: "idx_storage_assignments_unique_path_per_instance"

    add_check_constraint :system_storage_assignments,
      "status IN ('pending', 'provisioning', 'mounted', 'degraded', 'unmounting', 'failed', 'disabled')",
      name: "system_storage_assignments_status_check"
    add_check_constraint :system_storage_assignments,
      "encryption_mode IN ('inherit', 'none', 'fscrypt', 'luks', 'client_side_aes')",
      name: "system_storage_assignments_encryption_mode_check"
  end
end
