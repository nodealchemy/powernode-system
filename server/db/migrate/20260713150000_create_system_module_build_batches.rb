# frozen_string_literal: true

# Campaign 019f5885 inc9 (Part A) — the operator-visible unit of a native
# module-build run, replacing "the Gitea run" as the thing an operator looks
# at to see "did this push's module rebuild succeed." One row per build run
# (triggered by a push, a manual request, or a CVE-driven rebuild).
#
# Members are the `ci.module_build` System::Task rows dispatched for this
# batch (Part B's orchestrator creates one per planned module, stamping
# `options["batch_id"] = <this batch's id>` — see
# System::ModuleBuildBatch#member_tasks). This migration only creates the
# batch table itself; it does not touch system_tasks (options is
# schemaless JSONB, already GIN-indexed from the 019f2c3d baseline).
class CreateSystemModuleBuildBatches < ActiveRecord::Migration[8.1]
  def change
    create_table :system_module_build_batches, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :account_id, null: false

      t.string :status, null: false, default: "planning"
      t.string :trigger, null: false, default: "push" # push | manual | cve

      t.string :base_sha, null: false
      t.string :head_sha, null: false

      t.jsonb :module_slugs, null: false, default: []

      t.integer :planned_count, null: false, default: 0
      t.integer :succeeded_count, null: false, default: 0
      t.integer :failed_count, null: false, default: 0

      t.text :error_message

      t.datetime :dispatched_at
      t.datetime :awaiting_signature_at
      t.datetime :publishing_at
      t.datetime :completed_at
      t.datetime :failed_at

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :system_module_build_batches, :account_id
    add_index :system_module_build_batches, :status
    add_index :system_module_build_batches, :trigger
    add_index :system_module_build_batches, :module_slugs, using: :gin
  end
end
