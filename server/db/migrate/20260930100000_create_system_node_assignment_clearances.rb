# frozen_string_literal: true

# IMP-9f4e162d9ed1 - the platform's per-module statement that it unassigned a
# module from a node.
#
# The agent fails closed on an assignment list that names no data-bearing module
# while modules are attached (IMP-1023e79cc82d): an empty list cannot tell "the
# operator unassigned everything" from a degraded answer. This table is what lets
# it tell. A row is written ONLY by System::AssignmentClearanceService, from the
# server actions that remove a module from a node's served list (an assignment
# destroyed or disabled, a module disabled or destroyed), and is served on the
# node_api modules response as data.confirmed_unassigned. The agent detaches on
# an empty list only a module named there.
#
# It is a table, not a key on system_nodes.config, on purpose: node config is
# operator-writable through the ordinary node update verbs, and a confirmation
# an operator (or an agent holding nodes.update) can write without an audit row
# is not a confirmation. Nothing but the service writes here.
#
# node_module_id carries NO foreign key: the module may itself have been
# destroyed, which is one of the removals this records. Rows die with their node
# (cascade) and with the account, and expire on their own (expires_at).
#
# Guarded by table_exists? because server/db/schema.rb already carries this
# table: a fresh database built with db:schema:load still sees this migration as
# pending (the schema version header predates it), and an unguarded create_table
# there raises PG::DuplicateTable and aborts every later migration.
class CreateSystemNodeAssignmentClearances < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:system_node_assignment_clearances)

    create_table :system_node_assignment_clearances, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true
      t.references :node, null: false, type: :uuid, foreign_key: { to_table: :system_nodes, on_delete: :cascade }
      t.uuid :node_module_id, null: false
      t.string :reason, null: false
      t.datetime :issued_at, null: false
      t.datetime :expires_at, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :system_node_assignment_clearances, %i[node_id node_module_id], unique: true,
              name: "index_node_assignment_clearances_on_node_and_module"
    add_index :system_node_assignment_clearances, :node_module_id
    add_index :system_node_assignment_clearances, :expires_at
  end

  def down
    drop_table :system_node_assignment_clearances, if_exists: true
  end
end
