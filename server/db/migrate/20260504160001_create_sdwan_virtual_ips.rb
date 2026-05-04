# frozen_string_literal: true

# Sdwan::VirtualIp — first-class VIP object hosted by one or more peers
# in an SDWAN network. Slice 9b ships static-mode VIPs (operator
# designates a holder, agent configures the address on loopback,
# topology compiler emits AllowedIPs so other peers route through).
# Slice 9c lights up BGP-anycast mode: multiple holders announce the
# same /32 simultaneously, BGP closest-path picks the destination.
#
# Slice 9b of the SDWAN plan (we-are-continuing-development-spicy-bear.md).
class CreateSdwanVirtualIps < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_virtual_ips, id: :uuid do |t|
      t.references :sdwan_network, null: false, type: :uuid, foreign_key: true
      t.references :account,       null: false, type: :uuid, foreign_key: true

      t.string :name, null: false                  # uniq per network (operator label)
      # CIDR — typically /32 (v4) or /128 (v6) but can be wider when the
      # operator wants subnet-as-VIP semantics. Validated at the model layer.
      t.string :cidr, null: false
      t.text   :description
      t.string :tags, array: true, default: []

      # anycast=false: single active holder; failover via failover_holder_peer_ids.
      # anycast=true:  every entry in holder_peer_ids announces simultaneously
      #                (slice 9c BGP), traffic distributed by closest-path.
      t.boolean :anycast, default: false, null: false

      # Ordered: first entry is the primary holder when anycast=false.
      # When anycast=true: every entry announces concurrently (slice 9c).
      t.uuid :holder_peer_ids, array: true, default: []

      # Used only when anycast=false. Ordered list of peers to fail over
      # to when the primary holder fails. Slice 9f's failover sensor walks
      # this list.
      t.uuid :failover_holder_peer_ids, array: true, default: []

      # pending     — created but no assignment yet
      # active      — at least one holder is currently advertising
      # failing_over — between assignments (transient; <1s typical)
      # unassigned  — explicitly cleared by operator
      # error       — terminal failure (e.g., loopback collision)
      t.string :state, default: "pending", null: false

      # Slice 9c BGP knobs — shipped with 9b so the column exists without
      # a migration churn between sub-slices.
      t.integer :advertised_med, default: 0
      t.integer :advertised_local_pref, default: 100

      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :sdwan_virtual_ips, %i[sdwan_network_id name], unique: true
    add_index :sdwan_virtual_ips, %i[account_id cidr], unique: true
    add_index :sdwan_virtual_ips, :state
    add_index :sdwan_virtual_ips, :anycast
  end
end
