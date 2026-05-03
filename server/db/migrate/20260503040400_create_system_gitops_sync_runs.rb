# frozen_string_literal: true

# Per-tick audit log for GitOps reconciliation. One row per reconcile attempt
# (manual `sync_now` or scheduled tick). Persisted for 90 days for routine
# audit; trimmed by FleetEvent retention sweep.
#
# Reference: comprehensive stabilization sweep P5.
class CreateSystemGitopsSyncRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :system_gitops_sync_runs, id: :uuid do |t|
      t.references :gitops_repository, null: false, type: :uuid,
                   foreign_key: { to_table: :system_gitops_repositories }
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.integer :diff_count, default: 0, null: false
      t.uuid :proposal_ids, array: true, default: []
      t.string :status, default: "running", null: false  # running | success | failed | partial
      t.string :synced_revision
      t.text :error_message
      t.jsonb :diff_summary, default: {}

      t.timestamps
    end

    add_index :system_gitops_sync_runs, :started_at
    add_index :system_gitops_sync_runs, :status
  end
end
