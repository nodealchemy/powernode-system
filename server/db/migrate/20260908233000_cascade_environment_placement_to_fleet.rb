# frozen_string_literal: true

# Environment campaign, increment 3 follow-up — placement cascades.
#
# Increment 1 gave every fleet row its own environment and backfilled all of
# them to the account default. An operator then placed the control-plane
# template and the CI template through system_update_template — and nothing
# moved underneath: a node or instance is placed on CREATE only, so every
# existing row stayed in the default plane, and the gate (which reads the
# INSTANCE's plane first) still saw the live control plane as dev.
#
# The models now cascade a move to the children that were still in the
# parent's previous plane. This migration applies the same rule ONCE to the
# rows placed before the cascade existed: a node whose template sits in
# another plane while the node itself is still in the account DEFAULT follows
# its template; an instance still in the default while its node sits
# elsewhere follows its node. A row an operator placed explicitly (anything
# not in the default plane) is left alone — there is no way to tell an
# explicit default placement from a never-placed one, and following the
# template is what every such row would have done had it been created after
# placement.
class CascadeEnvironmentPlacementToFleet < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL.squish
      UPDATE system_nodes n SET environment_id = t.environment_id, updated_at = NOW()
      FROM system_node_templates t, ai_environments d
      WHERE t.id = n.node_template_id
        AND d.id = n.environment_id AND d.is_default
        AND t.environment_id <> n.environment_id
    SQL

    execute <<~SQL.squish
      UPDATE system_node_instances i SET environment_id = n.environment_id, updated_at = NOW()
      FROM system_nodes n, ai_environments d
      WHERE n.id = i.node_id
        AND d.id = i.environment_id AND d.is_default
        AND n.environment_id <> i.environment_id
    SQL
  end

  # A one-shot re-placement; the rows it moved carry no record of where they
  # were, and "back to the default" would also undo later explicit moves.
  def down; end
end
