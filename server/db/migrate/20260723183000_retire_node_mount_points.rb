# frozen_string_literal: true

# IMP-ad21fb7b9965 — retire the NodeMountPoint family (operator decision).
# Dead-end plumbing: no code path ever created system_instance_mount_points
# rows, so definitions could never attach to an instance. Both tables were
# verified EMPTY on drop. Storage-backed mounts live on
# System::StorageAssignment (Phase S2). down() restores the baseline shape
# (20250101000009_system_baseline) so the drop is reversible.
class RetireNodeMountPoints < ActiveRecord::Migration[8.1]
  def up
    drop_table :system_instance_mount_points, if_exists: true
    drop_table :system_node_mount_points, if_exists: true
  end

  def down
    create_table :system_node_mount_points, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid "account_id", null: false
      t.boolean "auto_mount", default: true, null: false
      t.datetime "created_at", null: false
      t.text "description"
      t.boolean "enabled", default: true, null: false
      t.string "mount_path", null: false
      t.string "mount_type", default: "nfs", null: false
      t.string "name", null: false
      t.jsonb "options", default: {}, null: false
      t.string "source"
      t.datetime "updated_at", null: false
      t.index [ "account_id", "name" ], unique: true
      t.index [ "account_id" ]
      t.index [ "enabled" ]
      t.index [ "mount_type" ]
      t.index [ "options" ], name: "index_system_node_mount_points_on_options", using: :gin
      t.check_constraint "mount_type::text = ANY (ARRAY['tmpfs'::character varying::text, 'bind'::character varying::text, 'custom'::character varying::text])", name: "system_node_mount_points_type_check"
    end

    create_table :system_instance_mount_points, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.jsonb "config", default: {}, null: false
      t.datetime "created_at", null: false
      t.boolean "enabled", default: true, null: false
      t.uuid "mount_point_id", null: false
      t.uuid "node_instance_id", null: false
      t.string "status", default: "pending", null: false
      t.datetime "updated_at", null: false
      t.index [ "config" ], name: "index_system_instance_mount_points_on_config", using: :gin
      t.index [ "enabled" ]
      t.index [ "mount_point_id" ]
      t.index [ "node_instance_id", "mount_point_id" ], unique: true
      t.index [ "node_instance_id" ]
      t.index [ "status" ]
      t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'mounted'::character varying::text, 'unmounted'::character varying::text, 'error'::character varying::text])", name: "system_instance_mount_points_status_check"
    end

    add_foreign_key :system_node_mount_points, :accounts, column: :account_id
    add_foreign_key :system_instance_mount_points, :system_node_instances, column: :node_instance_id
    add_foreign_key :system_instance_mount_points, :system_node_mount_points, column: :mount_point_id
  end
end
