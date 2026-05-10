# frozen_string_literal: true

# Phase O5 — Sdwan::IpfixCollector represents an operator-configured
# IPFIX exporter target. The platform's compiler stamps an `ipfix:`
# block on each ovs-kind HostBridge entry in the per-host payload when
# an active collector exists for the account; the agent's
# OvsBridgeApplier wires `ovs-vsctl set Bridge <name> ipfix=...` to
# match. Linux bridges are not affected (no IPFIX support without OVS).
class CreateSdwanIpfixCollectors < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_ipfix_collectors, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true
      t.string :name, null: false
      t.string :host, null: false
      t.integer :port, null: false, default: 4739
      t.integer :sampling_rate, null: false, default: 1
      t.string :state, null: false, default: "active"
      t.jsonb :settings, null: false, default: {}

      t.timestamps
    end

    add_index :sdwan_ipfix_collectors, %i[account_id name],
              unique: true, name: "idx_sdwan_ipfix_account_name"
    add_index :sdwan_ipfix_collectors, :state

    add_check_constraint :sdwan_ipfix_collectors,
                         "port BETWEEN 1 AND 65535",
                         name: "chk_sdwan_ipfix_port_range"
    add_check_constraint :sdwan_ipfix_collectors,
                         "sampling_rate >= 1",
                         name: "chk_sdwan_ipfix_sampling_min"
    add_check_constraint :sdwan_ipfix_collectors,
                         "state IN ('active','disabled')",
                         name: "chk_sdwan_ipfix_state"
  end
end
