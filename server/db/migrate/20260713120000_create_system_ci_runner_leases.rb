# frozen_string_literal: true

# Campaign 019f5885 inc3 — Lease orchestration for ephemeral Gitea Act runners.
#
# A System::CiRunnerLease is the lifecycle/accounting/recycle wrapper around a
# pooled builder NodeInstance leased to CI work: acquire a warm builder →
# correlate it to the Gitea GitRunner it self-registered → track it through the
# workflow run → deregister + recycle the instance on release so no
# state/credential bleeds between jobs.
#
# git_runner_id is a PLAIN uuid (no FK): Devops::RunnerLifecycleService#delete_runner
# destroys the git_runners row on release, which a real FK would turn into an
# InvalidForeignKey. runner_name / runner_external_id are snapshotted on the lease
# so the audit trail survives that destroy.
class CreateSystemCiRunnerLeases < ActiveRecord::Migration[8.1]
  def change
    create_table :system_ci_runner_leases, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :account_id, null: false
      t.uuid :node_instance_id, null: false
      t.uuid :instance_pool_id
      t.uuid :git_runner_id # plain uuid, no FK — see class comment

      t.string :status, null: false, default: "leased"
      t.string :runner_name
      t.string :runner_external_id
      t.jsonb :runner_labels, null: false, default: []
      t.string :runner_scope, null: false, default: "org"
      t.string :git_owner
      t.string :git_repo
      t.string :purpose, null: false, default: "generic"
      t.boolean :ephemeral, null: false, default: false # inert in inc3 (see model)

      t.bigint :workflow_run_id # set by inc4 orchestrator
      t.string :workflow_run_repo

      t.datetime :leased_at
      t.datetime :registered_at
      t.datetime :busy_at
      t.datetime :releasing_at
      t.datetime :released_at
      t.datetime :errored_at
      t.text :error_message
      t.datetime :expires_at

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :system_ci_runner_leases, :account_id
    add_index :system_ci_runner_leases, :status
    add_index :system_ci_runner_leases, :node_instance_id
    add_index :system_ci_runner_leases, :workflow_run_id
    add_index :system_ci_runner_leases, :runner_name
  end
end
