# frozen_string_literal: true

# GPU/accelerator as a first-class instance-type capability (audit Priority 6).
# Columns (not JSONB) so GPU SKUs are queryable for scheduling, mirroring the
# existing vcpus / memory_mb column precedent + their by_* scopes.
class AddGpuToSystemProviderInstanceTypes < ActiveRecord::Migration[8.1]
  def change
    change_table :system_provider_instance_types, bulk: true do |t|
      t.integer :gpu_count, null: false, default: 0   # accelerators per instance
      t.string  :gpu_type                              # e.g. "H100", "L40S", "A100", "RTX4090"
      t.integer :gpu_memory_mb                         # per-GPU VRAM in MB
    end

    # GPU SKUs are a small subset of the catalog — a partial index keeps
    # by_gpu / system_find_node_with_gpu filtering fast without bloating the
    # index for the CPU-only majority.
    add_index :system_provider_instance_types, %i[gpu_type gpu_count],
              where: "gpu_count > 0",
              name: "idx_system_provider_instance_types_gpu"
  end
end
