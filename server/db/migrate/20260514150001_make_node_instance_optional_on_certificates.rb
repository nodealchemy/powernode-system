# frozen_string_literal: true

# P3.4-bis — Federation-peer certs (subject_kind="federation_peer") have
# no node_instance. Make node_instance_id nullable and add a direct
# account_id column. Backfill existing rows from node_instance.account_id.
# Add a CHECK constraint enforcing one of {node_instance_id, account_id}
# is present (so a federation-peer cert always has an account; an instance
# cert always has its instance reference).
class MakeNodeInstanceOptionalOnCertificates < ActiveRecord::Migration[8.0]
  def change
    change_column_null :system_node_certificates, :node_instance_id, true

    add_reference :system_node_certificates, :account,
      type: :uuid, null: true,
      foreign_key: { to_table: :accounts, on_delete: :cascade }

    reversible do |dir|
      dir.up do
        # NodeInstance does not have its own account_id column — the chain
        # is instance → node → account. Backfill via the two-join path.
        execute <<~SQL.squish
          UPDATE system_node_certificates AS c
          SET account_id = n.account_id
          FROM system_node_instances AS i
          JOIN system_nodes AS n ON n.id = i.node_id
          WHERE c.node_instance_id = i.id AND c.account_id IS NULL
        SQL
      end
    end

    add_check_constraint :system_node_certificates,
      "(node_instance_id IS NOT NULL) OR (account_id IS NOT NULL)",
      name: "node_certificates_owner_present"
  end
end
