# frozen_string_literal: true

# IMP-555e29eeb4ab: CloudSyncService (both sync_node_instances and
# sync_region_instances) and several read paths (node_instance_internal
# serializer, internal nodes_controller/node_instances_controller) have
# always referenced instance.last_synced_at as if it were a real column —
# it never existed on system_node_instances, so every real invocation that
# reaches an `update!(last_synced_at: ...)` call raised
# ActiveModel::UnknownAttributeError. That's the deeper reason the hourly
# CloudSync pass never actually reconciled provider-state drift: it wasn't
# just the missing termination sweep, the whole sync write path was broken.
class AddLastSyncedAtToSystemNodeInstances < ActiveRecord::Migration[8.1]
  def change
    add_column :system_node_instances, :last_synced_at, :datetime
    add_index :system_node_instances, :last_synced_at
  end
end
