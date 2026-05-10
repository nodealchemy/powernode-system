# frozen_string_literal: true

# Phase N1a follow-up — per-host short_id for collision-free iface
# naming. The VRF allocator assigns 1..9999 sequentially per host;
# both the VRF master device (`sdwan-<short_id>`) and the WG iface
# (`wg-sdwan-<short_id>`) derive from this id, decoupling kernel
# iface names from network UUID prefixes (which collide under
# UUIDv7 timestamp packing).
class AddShortIdToSdwanHostVrfAssignments < ActiveRecord::Migration[8.1]
  def change
    add_column :sdwan_host_vrf_assignments, :short_id, :integer, null: false

    add_index :sdwan_host_vrf_assignments, %i[node_instance_id short_id],
              unique: true, name: "index_sdwan_hva_on_host_and_short_id"

    add_check_constraint :sdwan_host_vrf_assignments,
                         "short_id BETWEEN 1 AND 9999",
                         name: "sdwan_hva_short_id_range"
  end
end
