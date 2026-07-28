# frozen_string_literal: true

# An operator hold that blocks the platform from starting an instance while
# offline work is in progress on its disks.
#
# WHY. On 2026-07-27 ops-hub (the control plane itself) was stopped so its
# /persist could be edited from the hypervisor. Something issued a start 30
# SECONDS later, and for about a minute the guest and the host both had the same
# ext4 mounted read-write. A blob copied in during that window landed as a
# zero-byte file in the guest's view while hashing correctly from the host's, so
# every tool reported success and the node's frozen boot-LKG was left pointing at
# a truncated blob — a latent brick, invisible until a later boot.
#
# Modelled as a LEASE, not a boolean: an unattributed flag that blocks starts is
# indistinguishable from a bug six months later, and the operator who set it is
# the one piece of context that makes it safe to clear. Expiry ALERTS but does
# not auto-release — a hold that lifts itself mid-maintenance defeats the entire
# purpose.
class AddOpsHoldToSystemNodeInstances < ActiveRecord::Migration[8.0]
  def change
    change_table :system_node_instances, bulk: true do |t|
      t.datetime :ops_hold_at
      t.datetime :ops_hold_expires_at
      t.string   :ops_hold_reason
      t.uuid     :ops_hold_by_id
      # What the PROVIDER reports, recorded separately from our intent so the
      # two can be compared. A platform-side flag alone would not have prevented
      # the incident if the start came from outside the platform.
      t.string   :ops_hold_provider_state
    end

    add_index :system_node_instances, :ops_hold_at,
              where: "ops_hold_at IS NOT NULL",
              name: "idx_system_node_instances_on_ops_hold"
    add_foreign_key :system_node_instances, :users, column: :ops_hold_by_id
  end
end
