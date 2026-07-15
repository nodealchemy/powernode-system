# frozen_string_literal: true

# Campaign 019f6084 inc-M — first-class task-scoped lease on node instances.
#
# Reifies P0-A's DECORATIVE config["fulfillment_lease"] blob (which nothing ever
# reaped) into two governable columns:
#   lifecycle_class  — e.g. "task_scoped": this instance was leased for the
#                      duration of one on-demand fulfillment, not owned forever.
#   lease_expires_at — when that lease elapses; the fulfillment reaper
#                      (System::FulfillmentRequestSweepService) TERMINATES the
#                      instance once it passes, so on-demand creation can't
#                      accrete a zombie fleet.
#
# Only FRESH-provisioned fulfillment instances carry a task_scoped lease; re-used
# scoped-pool members stay governed by the pool reaper's claimed_ttl (never
# double-governed). The config blob is retained for the operator-visible detail.
class AddTaskScopedLeaseToSystemNodeInstances < ActiveRecord::Migration[8.1]
  def change
    add_column :system_node_instances, :lifecycle_class, :string
    add_column :system_node_instances, :lease_expires_at, :datetime

    # Reaper query: task-scoped instances whose lease has elapsed. Partial index
    # keeps it tiny (the vast majority of instances carry no lease).
    add_index :system_node_instances, [ :lifecycle_class, :lease_expires_at ],
              name: "idx_node_instances_task_scoped_lease",
              where: "lifecycle_class IS NOT NULL"
  end
end
