# frozen_string_literal: true

# IMP-f2a7a729d39b — retire `system_nodes.lifecycle_class`, step 2 of 2.
#
# Step 1 (20260902160000, IMP-19843220ac68) stopped both application writers
# and made the column nullable with a NULL default, deliberately leaving the
# column, its `chk_system_nodes_lifecycle_class` CHECK constraint and
# `index_system_nodes_on_lifecycle_class` in place for one deploy window, so
# the previous release could keep running FORWARD against the migrated schema.
# That window has passed. The reading taken before this migration was written:
# step 1's commit 7b3fef5b is an ANCESTOR of the extension revision running on
# ops-hub (c581915c), which shipped with the second platform deploy of
# 2026-09-03 and stayed live across the third deploy the same day. So this
# drops the three schema objects. In the same change the model loses
# `System::Node::LIFECYCLE_CLASSES` and its inclusion validation, and the
# `example_multi_tenant` dev seed (the one writer step 1 left out of scope)
# stops writing the column. Nothing reads it; nothing ever did.
#
# ORDER: the index and the CHECK are removed explicitly before the column.
# Postgres would drop both with the column anyway, but naming them keeps `down`
# an exact inverse of `up`, which is the whole justification for the order.
# System::SchemaDriftDetector is unaffected either way and is NOT a reason:
# both objects were declared inside `create_table` in 20250101000009 (`t.string`
# / `t.index`), and its scan only adds objects matched by `add_column` /
# `add_index ... name:`, so neither was ever in its added set and there is
# nothing here for the explicit removes to subtract.
#
# `if_exists: true` on all three: this runs unattended at boot on a
# self-hosted hub (rails-start.sh → db:migrate), where a failed migration is
# a boot failure. A hub whose schema has already lost one of these objects —
# a hand-applied drop, or the stamped-without-DDL drift the drift backstop
# exists for — must not be bricked by a step whose whole purpose is that the
# object be gone. The drift backstop, not this migration, is where a missing
# object gets reported.
#
# `down` RESTORES STEP 1's END STATE, not the baseline: nullable, no default,
# CHECK and index back, and every row NULL. The values are gone with the
# column and nothing can recompute them here; step 1's own `down` carries the
# pool-resolving backfill and restores NOT NULL, and runs next when step 1 is
# reverted. That is exactly the shape a module rollback to the step-1 release
# needs: that release's model validates the column (allow_nil) and raises
# NoMethodError on every Node validation while the attribute is missing. Roll
# the extension back past step 2 ONLY after running this `down`.
class DropLifecycleClassFromSystemNodes < ActiveRecord::Migration[8.1]
  # The value space the CHECK enforced from the baseline through step 1;
  # Postgres normalises it to the `= ANY (ARRAY[...])` form on dump.
  CHECK_EXPRESSION = "lifecycle_class IN ('persistent', 'ephemeral', 'spot')"

  def up
    remove_index :system_nodes, name: "index_system_nodes_on_lifecycle_class", if_exists: true
    remove_check_constraint :system_nodes, name: "chk_system_nodes_lifecycle_class", if_exists: true
    remove_column :system_nodes, :lifecycle_class, if_exists: true
  end

  def down
    add_column :system_nodes, :lifecycle_class, :string
    add_check_constraint :system_nodes, CHECK_EXPRESSION, name: "chk_system_nodes_lifecycle_class"
    add_index :system_nodes, :lifecycle_class, name: "index_system_nodes_on_lifecycle_class"
  end
end
