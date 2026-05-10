# frozen_string_literal: true

# Adds the `sdwan_ovn_acls` table — per-logical-switch firewall rules
# expressed in OVN's match-language and rendered to `acl-add` commands
# by Sdwan::OvnCompiler.
#
# An ACL is the OVN equivalent of a firewall rule scoped to one logical
# switch. It has:
#
#   - direction: from-lport (egress from the source) | to-lport (ingress
#                to the destination)
#   - priority: integer; higher values evaluated first. OVN's range is
#                0..32767. Multiple ACLs at the same priority match in
#                lexicographic match-string order.
#   - match:    OVN match expression (e.g., `ip4.src == 10.0.0.0/8 &&
#                tcp.dst == 5432`). Raw OVN syntax stored as text — the
#                model doesn't parse it; OVN's own parser rejects bad
#                values at apply time.
#   - action:   allow | drop | reject | allow-related (the OVN-defined
#                vocabulary).
#
# Each ACL belongs to exactly one OvnLogicalSwitch (and through the
# switch, an OvnDeployment). Cross-switch ACLs aren't a real OVN concept
# at the NB level; for cross-switch behavior operators chain per-switch
# ACLs.
#
# Lifecycle (AASM column: state):
#   pending → row created; not yet emitted to OVN
#   active  → compiler is emitting it; northd has compiled it into SB
#   removed → operator/AI deleted it; row stays for audit but is
#             excluded from compiler emissions (mirrors switches/ports)
#
# Phase O6 follow-up — multi-tenant isolation surface for the OVS+OVN
# heavyweight track.
class CreateSdwanOvnAcls < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_ovn_acls, id: :uuid do |t|
      t.references :sdwan_ovn_logical_switch, type: :uuid, null: false,
                   foreign_key: { to_table: :sdwan_ovn_logical_switches, on_delete: :cascade },
                   index: true
      t.references :account, type: :uuid, null: false,
                   foreign_key: true, index: true

      t.string  :name,      null: false, limit: 63
      t.string  :direction, null: false, limit: 16
      t.integer :priority,  null: false, default: 1000
      t.text    :match,     null: false
      t.string  :action,    null: false, limit: 16
      t.string  :state,     null: false, default: "pending", limit: 16

      t.datetime :activated_at
      t.datetime :removed_at
      t.timestamps
    end

    # Compiler emits in (priority desc, name asc) order. Composite index
    # keeps that scan cheap as the ACL count grows; per-switch scope
    # keeps the index tight.
    add_index :sdwan_ovn_acls,
              %i[sdwan_ovn_logical_switch_id state priority name],
              name: "idx_ovn_acls_compile_order"

    # ACL names are unique per logical switch — the compose skill uses
    # name as the idempotency key. Uniqueness is per-switch (not
    # per-deployment) because the same name on different switches is a
    # legitimate operator pattern (e.g., "deny-all" on each tier).
    add_index :sdwan_ovn_acls,
              %i[sdwan_ovn_logical_switch_id name],
              unique: true,
              name: "idx_ovn_acls_unique_name_per_switch"
  end
end
