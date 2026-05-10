# frozen_string_literal: true

# Sdwan::HostVrfAssignment — joins a NodeInstance (host) to a network
# with the Linux VRF that scopes that network's routing table on that
# host. table_id is allocated by Sdwan::VrfAllocator from the
# 100..65535 range, skipping the kernel-reserved tables (254=main,
# 255=local, 253=default, 0=unspec).
#
# Lifecycle states (AASM):
#   pending  → created, agent has not yet applied the VRF
#   active   → agent has confirmed the VRF master device is up and the
#              network's WG iface is bound to it
#   draining → operator/AI requested removal; entry is preserved until
#              tunnels using the table-id finish their grace window so
#              the same id is not reused under in-flight traffic
#   removed  → agent confirmed the VRF master device is gone; row is
#              kept for audit but excluded from compiler output
#
# Phase N1a of the in-house encrypted mesh overlay roadmap.
class CreateSdwanHostVrfAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_host_vrf_assignments, id: :uuid do |t|
      t.references :node_instance, null: false, type: :uuid,
                   foreign_key: { to_table: :system_node_instances }
      t.references :sdwan_network, null: false, type: :uuid,
                   foreign_key: true
      t.references :account, null: false, type: :uuid, foreign_key: true

      # Per-host kernel routing table identifier in the range 100..65535.
      # Allocator skips the four reserved values; check constraint below
      # catches any direct insert that bypasses the allocator.
      t.integer :table_id, null: false

      # Derived from Sdwan::Network#vrf_name_template — kept on the row
      # so the agent can read the desired iface name without re-running
      # template substitution. Bound by IFNAMSIZ (15 chars).
      t.string :vrf_name, null: false, limit: 15

      t.string :state, null: false, default: "pending"

      t.datetime :applied_at
      t.datetime :draining_at
      t.datetime :removed_at

      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    # A host joins each network at most once → unique (host, network)
    add_index :sdwan_host_vrf_assignments,
              %i[node_instance_id sdwan_network_id], unique: true,
              name: "index_sdwan_hva_on_host_and_network"

    # Per-host table-id and vrf-name uniqueness — both are kernel
    # identifiers that cannot collide on the same host.
    add_index :sdwan_host_vrf_assignments,
              %i[node_instance_id table_id], unique: true,
              name: "index_sdwan_hva_on_host_and_table_id"
    add_index :sdwan_host_vrf_assignments,
              %i[node_instance_id vrf_name], unique: true,
              name: "index_sdwan_hva_on_host_and_vrf_name"

    add_index :sdwan_host_vrf_assignments, :state

    add_check_constraint :sdwan_host_vrf_assignments,
                         "table_id BETWEEN 100 AND 65535 AND " \
                         "table_id NOT IN (253, 254, 255)",
                         name: "sdwan_hva_table_id_range"

    add_check_constraint :sdwan_host_vrf_assignments,
                         "state IN ('pending','active','draining','removed')",
                         name: "sdwan_hva_state_check"
  end
end
