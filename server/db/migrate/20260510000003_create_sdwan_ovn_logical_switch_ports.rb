# frozen_string_literal: true

# Sdwan::OvnLogicalSwitchPort — a port on a logical switch. Maps 1:1 to
# OVN's `Logical_Switch_Port` row in the Northbound DB. Each port has a
# kind (`vm` | `container` | `external`); host_node_instance_id is set
# for vm/container ports (the host that physically backs the port) and
# left null for external ports (router uplinks, transit ports).
#
# MAC addressing: the model auto-generates a locally-administered MAC
# (`02:` prefix + random) when one isn't supplied, so the operator can
# create a port without knowing the eventual MAC. The `02:` prefix
# selects the IEEE locally-administered range — guaranteed never to
# collide with hardware-assigned vendor OUIs.
#
# Lifecycle states (AASM):
#   pending → row created; not yet emitted to northd
#   active  → compiler is emitting it; the port exists in OVN
#   removed → operator/AI deleted it; row stays for audit but the
#             compiler skips it
#
# Phase O3 of the OVS+OVN dual-profile roadmap (heavyweight track).
class CreateSdwanOvnLogicalSwitchPorts < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_ovn_logical_switch_ports, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true
      t.references :sdwan_ovn_logical_switch, null: false, type: :uuid,
                   foreign_key: true,
                   index: { name: "index_sdwan_ovn_lsps_on_lswitch" }

      # Nullable — null for external ports (router uplinks, transit
      # ports) where no specific host backs the port. Set for vm and
      # container ports so the agent on the backing host knows to
      # bring the local OVS interface up.
      t.references :host_node_instance, type: :uuid,
                   foreign_key: { to_table: :system_node_instances },
                   index: { name: "index_sdwan_ovn_lsps_on_host_instance" }

      # OVN port name — bounded by the same 63-char limit as switches.
      t.string :name, null: false, limit: 63

      # Locally-administered MAC (`02:...`). Auto-generated on create
      # when blank — see Sdwan::OvnLogicalSwitchPort.generate_mac.
      t.string :mac, null: false, limit: 17

      # Array of address strings. OVN accepts mixed v4/v6 in a single
      # row (`addresses=["02:.. 10.0.0.5", "02:.. fd00::5"]`) so we
      # store the full list as JSONB.
      t.jsonb :addresses, default: [], null: false

      # Port kind — drives compiler choices (external ports need a
      # router-port partner; vm ports need iface-id binding metadata).
      t.string :kind, null: false, default: "vm"

      t.string :state, null: false, default: "pending"

      t.jsonb :settings, default: {}, null: false

      t.datetime :activated_at
      t.datetime :removed_at

      t.timestamps
    end

    # Port names must be unique within a logical switch — OVN rejects
    # duplicates at the NB DB layer.
    add_index :sdwan_ovn_logical_switch_ports,
              %i[sdwan_ovn_logical_switch_id name], unique: true,
              name: "index_sdwan_ovn_lsps_on_lswitch_and_name"

    add_index :sdwan_ovn_logical_switch_ports, :state
    add_index :sdwan_ovn_logical_switch_ports, :kind

    add_check_constraint :sdwan_ovn_logical_switch_ports,
                         "state IN ('pending','active','removed')",
                         name: "sdwan_ovn_lsps_state_check"

    add_check_constraint :sdwan_ovn_logical_switch_ports,
                         "kind IN ('vm','container','external')",
                         name: "sdwan_ovn_lsps_kind_check"
  end
end
