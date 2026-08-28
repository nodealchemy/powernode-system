# frozen_string_literal: true

# Batch-atomic promotion (2026-08-28 outage remediation).
#
# Publishing AUTO-PROMOTES, per module, the moment each build finishes. Build
# durations across one batch differ by an order of magnitude — measured
# 2026-08-28: powernode-extension-system ~2 min, powernode-hub-backend ~20 min —
# so a batch spanning core and extension has a guaranteed skew window. In that
# window ops-hub ran the new extension against the old core, could not boot
# (`undefined method 'declare_action'`), and crash-looped for ~25 minutes with
# MCP down alongside it.
#
# This column marks a version that was PUBLISHED but deliberately not promoted
# because its batch is still in flight. The orchestrator promotes the whole set
# together when the batch completes.
class AddDeferredPromotionBatchToNodeModuleVersions < ActiveRecord::Migration[8.0]
  def change
    add_column :system_node_module_versions, :deferred_promotion_batch_id, :uuid, null: true

    # Partial: only deferred rows are ever queried, and they are a vanishing
    # fraction of the table.
    add_index :system_node_module_versions, :deferred_promotion_batch_id,
              where: "deferred_promotion_batch_id IS NOT NULL",
              name: "idx_module_versions_deferred_promotion_batch"
  end
end
