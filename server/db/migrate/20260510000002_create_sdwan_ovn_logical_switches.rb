# frozen_string_literal: true

# Sdwan::OvnLogicalSwitch — a logical L2 broadcast domain inside an OVN
# deployment. Maps 1:1 to OVN's `Logical_Switch` row in the Northbound
# DB; the compiler emits an `ls-add <name>` line for each active row.
#
# Naming constraint: OVN's logical-switch name field is bounded at 63
# bytes (matches `ovn-nbctl`'s validation). The model enforces this at
# both Ruby and DB layers so a bad name never reaches northd.
#
# Lifecycle states (AASM):
#   pending → row created; not yet emitted to northd
#   active  → compiler is emitting it; ovn-northd has compiled it into
#             the SB DB
#   removed → operator/AI tore it down; row stays for audit but the
#             compiler skips it (mirrors HostBridge.removed semantics)
#
# Phase O3 of the OVS+OVN dual-profile roadmap (heavyweight track).
class CreateSdwanOvnLogicalSwitches < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_ovn_logical_switches, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true
      t.references :sdwan_ovn_deployment, null: false, type: :uuid,
                   foreign_key: true,
                   index: { name: "index_sdwan_ovn_lswitches_on_deployment" }

      # OVN's hard cap on Logical_Switch.name is 63 chars — set this as
      # the column limit so the DB rejects oversize names even if the
      # Ruby validator is bypassed.
      t.string :name, null: false, limit: 63

      # Optional CIDR — used for OVN DHCP_Options when set. Stored as
      # text so the operator can pass either v4 or v6 prefixes; the
      # compiler synthesizes the DHCP_Options payload from this column.
      t.string :cidr, limit: 64
      t.string :description

      t.string :state, null: false, default: "pending"

      t.jsonb :settings, default: {}, null: false

      t.datetime :activated_at
      t.datetime :removed_at

      t.timestamps
    end

    # Logical-switch names must be unique within a deployment — OVN
    # rejects duplicates at the NB DB layer, so we mirror it here.
    add_index :sdwan_ovn_logical_switches,
              %i[sdwan_ovn_deployment_id name], unique: true,
              name: "index_sdwan_ovn_lswitches_on_deployment_and_name"

    add_index :sdwan_ovn_logical_switches, :state

    add_check_constraint :sdwan_ovn_logical_switches,
                         "state IN ('pending','active','removed')",
                         name: "sdwan_ovn_lswitches_state_check"
  end
end
