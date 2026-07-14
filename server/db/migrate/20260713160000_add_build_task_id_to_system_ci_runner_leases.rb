# frozen_string_literal: true

# Campaign 019f5885 inc9 Part B — the purpose-aware sweep correlates a
# `module_build` lease to its `ci.module_build` System::Task by id instead of
# a Gitea workflow_run_id (module-forge builders never register as Gitea Act
# runners, so workflow_run_id is always nil for this purpose). Plain uuid, no FK
# — mirrors git_runner_id's existing "snapshot, not referential integrity"
# posture on this same table (a Task row is looked up defensively via
# find_by, tolerating a stale/missing id rather than enforcing a constraint).
class AddBuildTaskIdToSystemCiRunnerLeases < ActiveRecord::Migration[8.1]
  def change
    add_column :system_ci_runner_leases, :build_task_id, :uuid
    add_index :system_ci_runner_leases, :build_task_id
  end
end
