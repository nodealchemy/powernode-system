# frozen_string_literal: true

# IMP-1e2e7b43b083 — `system_node_instances.lifecycle_class` (added by
# 20260715120100_add_task_scoped_lease_to_system_node_instances.rb) borrowed a
# name that already meant something else on two other tables.
#
#   system_nodes.lifecycle_class           persistent|ephemeral|spot  (CHECK)
#   system_instance_pools.lifecycle_class  ephemeral|spot             (CHECK)
#   system_node_instances.lifecycle_class  task_scoped, nullable, no CHECK
#
# The first two are deliberate LAYERING — the pool value space is a correct
# strict subset of the node one, and InstancePoolService#provision_warming_member!
# copies pool → node across that relation. The third is a DIFFERENT AXIS: it
# answers "why was this instance leased" (fulfillment reaper provenance), not
# "how long-lived is this machine", and its only value would violate the CHECK
# constraint standing on either sibling table. Renaming it to `lease_class`
# makes the name answer "which value space?" on its own.
#
# Postgres rewrites index predicates on a column rename, so the reaper's partial
# index `idx_node_instances_task_scoped_lease` follows the column (its WHERE
# becomes `lease_class IS NOT NULL`) and keeps its explicit name — Rails only
# auto-renames indexes still carrying the generated default name.
#
# Reversible by construction: `rename_column` inside `change` inverts itself.
class RenameLifecycleClassToLeaseClassOnSystemNodeInstances < ActiveRecord::Migration[8.1]
  def change
    rename_column :system_node_instances, :lifecycle_class, :lease_class
  end
end
