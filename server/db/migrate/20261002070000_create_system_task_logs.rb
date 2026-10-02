# frozen_string_literal: true

# IMP-dbc22946e05c - the FULL scrubbed log of a task, uploaded by the on-node
# agent. System::Task#events carries only a scrubbed tail (a module build's
# log_tail, 4 KB of stdout and 128 KB of stderr): a failure whose cause scrolled
# out of that window could not be diagnosed over MCP, and the operator had to go
# to the builder host.
#
# A table of its own, not a key on the task's jsonb events, on purpose: events is
# read whole on every task fetch, and a build log can be a megabyte. One row per
# task (unique task_id), replaced by a re-upload, bounded in size by
# System::TaskLogStore, and expiring on its own (expires_at). content is stored
# ALREADY REDACTED and is redacted again when read.
#
# Rows die with their task (cascade) and with the account.
#
# Guarded by table_exists? because server/db/schema.rb already carries this
# table: a fresh database built with db:schema:load still sees this migration as
# pending (the schema version header predates it), and an unguarded create_table
# there raises PG::DuplicateTable and aborts every later migration.
class CreateSystemTaskLogs < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:system_task_logs)

    create_table :system_task_logs, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true
      t.references :task, null: false, type: :uuid, index: false,
                          foreign_key: { to_table: :system_tasks, on_delete: :cascade }
      t.uuid :node_instance_id
      t.text :content, null: false, default: ""
      t.integer :byte_size, null: false, default: 0
      t.bigint :original_bytes, null: false, default: 0
      t.boolean :truncated, null: false, default: false
      t.datetime :expires_at, null: false
      t.timestamps
    end

    add_index :system_task_logs, :task_id, unique: true
    add_index :system_task_logs, :expires_at
    add_index :system_task_logs, :node_instance_id
  end

  def down
    drop_table :system_task_logs, if_exists: true
  end
end
