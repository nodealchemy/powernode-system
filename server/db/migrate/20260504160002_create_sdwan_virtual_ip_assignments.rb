# frozen_string_literal: true

# Sdwan::VirtualIpAssignment — audit-grade history of which peer held a
# VIP at any given moment. One row per (vip, peer, assumed_at) tuple;
# released_at gets stamped when the holder changes. The current
# holder(s) are the row(s) where released_at IS NULL.
#
# Slice 9b of the SDWAN plan.
class CreateSdwanVirtualIpAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_virtual_ip_assignments, id: :uuid do |t|
      t.references :sdwan_virtual_ip, null: false, type: :uuid, foreign_key: true
      t.references :sdwan_peer,       null: false, type: :uuid, foreign_key: true

      t.datetime :assumed_at, null: false
      t.datetime :released_at

      # initial          — first assignment when VIP was created
      # manual_failover  — operator triggered failover via UI/MCP
      # sensor_failover  — slice 9f autonomy executor moved it
      # holder_changed   — operator edited holder_peer_ids on the VIP
      # revoked          — VIP destroyed; the row is final history
      t.string :reason, null: false

      t.uuid :triggered_by_user_id
      t.string :triggered_by_signal_correlation_id

      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :sdwan_virtual_ip_assignments, :released_at
    add_index :sdwan_virtual_ip_assignments,
              %i[sdwan_virtual_ip_id sdwan_peer_id],
              where: "released_at IS NULL",
              unique: true,
              name: "idx_sdwan_vip_assignments_one_active_holder_per_vip_peer"
  end
end
