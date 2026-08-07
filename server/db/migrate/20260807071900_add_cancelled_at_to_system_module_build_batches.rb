# frozen_string_literal: true

# System::ModuleBuildBatch gains a `cancelled` terminal state, and the model's
# AASM convention is that each event stamps its own timestamp column so the
# single transition save persists everything atomically. Cancelling is not
# failing — reusing failed_at would make an operator-stopped batch
# indistinguishable from one whose builds all failed, which is exactly the
# distinction #recompute_counts! and the partial/failed accounting rest on.
class AddCancelledAtToSystemModuleBuildBatches < ActiveRecord::Migration[8.0]
  def change
    add_column :system_module_build_batches, :cancelled_at, :datetime
  end
end
