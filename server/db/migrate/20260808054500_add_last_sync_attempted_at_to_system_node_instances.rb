# frozen_string_literal: true

# IMP-bcadb1ecd52d — the drift-sensor rotation ordered by SUCCESS-stamped
# last_synced_at, so never-stampable instances (no adapter, no cloud id,
# persistently failing provider reads) kept NULL forever and pinned the front
# of the capped window; with MAX_PER_TICK of them, every other instance was
# starved of drift checks. The sensor now orders by this attempt timestamp,
# stamped on EVERY attempt, while last_synced_at keeps its success-only
# convention for its existing readers.
class AddLastSyncAttemptedAtToSystemNodeInstances < ActiveRecord::Migration[8.0]
  def change
    add_column :system_node_instances, :last_sync_attempted_at, :datetime
    add_index :system_node_instances, :last_sync_attempted_at
  end
end
