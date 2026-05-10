# frozen_string_literal: true

# Sdwan::HostBridge — desired Linux/OVS bridge on a specific host
# (NodeInstance). Replaces the manually-created `pwnvbr0` bridge with
# an agent-managed, declarative bridge whose name + lifecycle the
# platform owns end-to-end.
#
# `kind` enum is currently `linux` only; the `ovs` variant lands in
# Phase O2 (heavyweight profile) and reuses the same model + applier
# interface (BridgeApplier strategy pattern).
#
# `short_id` is allocated per-host (1..9999) by Sdwan::HostBridgeAllocator
# and drives the kernel-visible bridge name (`pwnbr-<short_id>`). The
# 9999 ceiling keeps the widest derived name (`pwnbr-9999` = 10 chars)
# inside IFNAMSIZ (15 chars) with comfortable headroom.
#
# Lifecycle states (AASM):
#   pending  → row created; agent has not yet applied the bridge
#   active   → agent confirmed the bridge exists and is UP
#   draining → operator/AI requested removal; preserved so in-flight
#              taps using this bridge can finish their grace window
#              before the same short_id is reused
#   removed  → agent confirmed teardown; row stays for audit but is
#              excluded from compiler emissions
#
# Phase O1 of the OVS+OVN dual-profile roadmap (lightweight track).
class CreateSdwanHostBridges < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_host_bridges, id: :uuid do |t|
      t.references :node_instance, null: false, type: :uuid,
                   foreign_key: { to_table: :system_node_instances }
      t.references :account, null: false, type: :uuid, foreign_key: true

      # Per-host counter that drives the kernel-visible bridge name.
      # Allocator hands out 1..9999 sequentially per host; rows kept
      # in draining/removed states still hold their id during the
      # grace window so it isn't reissued under in-flight taps.
      t.integer :short_id, null: false

      # Kernel-visible bridge name — `pwnbr-<short_id>`, capped at
      # IFNAMSIZ (15 chars). Stored on the row so the agent can read
      # the desired name without re-deriving from short_id.
      t.string :bridge_name, null: false, limit: 15

      # Implementation strategy. `linux` is the only valid value in
      # Phase O1; `ovs` lands in Phase O2 (heavyweight profile).
      t.string :kind, null: false, default: "linux"

      # Optional desired addressing on the bridge. Tracks the host-side
      # /24 (or /N) that the bridge serves; the agent assigns this CIDR
      # to the bridge interface. NULL = bridge has no IP (L2-only).
      # Mirrors the historical 192.168.250.1/24 default for `pwnvbr0`.
      t.string :ipv4_cidr, limit: 64
      t.string :ipv6_cidr, limit: 64

      t.string :state, null: false, default: "pending"

      t.datetime :applied_at
      t.datetime :draining_at
      t.datetime :removed_at

      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    # A host carries a given short_id at most once — both the
    # allocator and direct inserts must collide on this index when
    # racing to mint the same id.
    add_index :sdwan_host_bridges,
              %i[node_instance_id short_id], unique: true,
              name: "index_sdwan_host_bridges_on_host_and_short_id"

    # Bridge name is derived from short_id but enforced as its own
    # unique constraint per-host so the kernel iface namespace stays
    # collision-free even if a future allocator change decouples them.
    add_index :sdwan_host_bridges,
              %i[node_instance_id bridge_name], unique: true,
              name: "index_sdwan_host_bridges_on_host_and_bridge_name"

    add_index :sdwan_host_bridges, :state

    add_check_constraint :sdwan_host_bridges,
                         "short_id BETWEEN 1 AND 9999",
                         name: "sdwan_host_bridges_short_id_range"

    add_check_constraint :sdwan_host_bridges,
                         "kind IN ('linux','ovs')",
                         name: "sdwan_host_bridges_kind_check"

    add_check_constraint :sdwan_host_bridges,
                         "state IN ('pending','active','draining','removed')",
                         name: "sdwan_host_bridges_state_check"
  end
end
