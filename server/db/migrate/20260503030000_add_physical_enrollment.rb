# frozen_string_literal: true

# Adds physical-device enrollment surface (Golden Eclipse plan
# wondrous-yawning-anchor — claim-code primary provisioning):
#
#   - Extends system_node_instances with claim_code + discovery columns,
#     so an instance can be visually paired with a real device by an
#     operator once that device first contacts /node_api/claim.
#
#   - Creates system_unclaimed_devices to hold devices that have polled
#     /claim but haven't been bound to a NodeInstance yet. Survives
#     across polls (upsert by (account_id, mac)) so the operator UI
#     can list pending devices in real time.
#
#   - Extends system_node_platforms with disk_image_* columns referencing
#     the FileManagement::Object that holds the generic .img for that
#     platform (one image per platform; per-instance baked images are
#     deferred to Phase 2).
#
# Reference: docs/plans/wondrous-yawning-anchor.md, NodeInstance
# discovery flow described in the plan §2.
class AddPhysicalEnrollment < ActiveRecord::Migration[8.1]
  def change
    # === NodeInstance discovery + claim columns ===
    change_table :system_node_instances, bulk: true do |t|
      t.string   :claim_code
      t.datetime :claimed_at
      t.string   :discovered_mac
      t.string   :discovered_dmi_uuid
      t.string   :discovered_hostname
      t.datetime :discovered_at
    end

    # claim_code is unique only when set — operator-initiated bookkeeping,
    # not a runtime constraint. Partial unique index keeps it efficient.
    add_index :system_node_instances, :claim_code,
              unique: true, where: "claim_code IS NOT NULL",
              name: "idx_node_instances_claim_code_unique"
    add_index :system_node_instances, :discovered_mac

    # === UnclaimedDevice table ===
    create_table :system_unclaimed_devices, id: :uuid do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid
      # 8-char [A-HJ-NP-Z2-9] alphabet (omit I/L/O/0/1 to avoid glyph
      # confusion when an operator reads the code off an HDMI console).
      # ~10^11 keyspace — collision probability negligible within the
      # 24h active window.
      t.string :claim_code, null: false
      t.string :discovered_mac
      t.string :discovered_dmi_uuid
      t.string :discovered_hostname
      t.string :agent_version
      t.string :architecture
      t.string :platform_hint
      t.references :claimed_node_instance,
                   foreign_key: { to_table: :system_node_instances },
                   type: :uuid
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at,  null: false
      # Auto-expire stale entries — reaper cron runs daily.
      t.datetime :expires_at, null: false
      t.datetime :claimed_at
      t.timestamps
    end

    add_index :system_unclaimed_devices, :claim_code, unique: true
    add_index :system_unclaimed_devices, :discovered_mac
    add_index :system_unclaimed_devices, :expires_at

    # === NodePlatform disk_image columns ===
    # One generic .img per platform — populated by the CI build workflow
    # via the existing webhook callback pattern. file_object_id refers
    # to FileManagement::Object so the existing FileStorageService
    # signed-URL path Just Works.
    change_table :system_node_platforms, bulk: true do |t|
      t.uuid     :disk_image_file_object_id
      t.string   :disk_image_sha256
      t.bigint   :disk_image_size_bytes
      t.datetime :disk_image_built_at
    end

    add_index :system_node_platforms, :disk_image_file_object_id,
              name: "idx_node_platforms_disk_image_file_object"
  end
end
