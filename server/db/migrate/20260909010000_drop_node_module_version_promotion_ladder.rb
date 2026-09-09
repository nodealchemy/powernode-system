# frozen_string_literal: true

# Environment campaign, increment 4b — delete the decorative promotion ladder.
#
# `promotion_state` (built | staging | blessed | live | retired) and its four
# timestamp columns described a lifecycle no node ever saw. What a node is
# served is NodeModule#current_version_id for a following environment and
# System::ModuleEnvironmentPin for a pinned one (increment 4a), so the label
# was free to disagree with reality and did: several versions of one module
# could sit at `live` at once, and versions observed at `live` on the live
# control plane 2026-09-01 carried `oci_digest: nil` — unmountable rows the
# CVE lane would have offered as remediation.
#
# The evidence the ladder claimed to gate on is real and survives:
# System::Fleet::PromotionCriteria now measures it for a promotion INTO a
# pinned environment, where "the rung below has run this and lived" is a
# question with an answer.
#
# Irreversible by design: `down` recreates the columns so a rollback of the
# code can run, but the labels themselves are not recoverable and nothing
# reads them. Their information — which versions a plane was put on, and by
# whom — lives in system_module_environment_pins from here on.
class DropNodeModuleVersionPromotionLadder < ActiveRecord::Migration[8.0]
  def up
    remove_check_constraint :system_node_module_versions,
                            name: "system_node_module_versions_promotion_state_check"
    remove_index :system_node_module_versions, :promotion_state, if_exists: true
    remove_column :system_node_module_versions, :promotion_state
    remove_column :system_node_module_versions, :staging_baked_at
    remove_column :system_node_module_versions, :blessed_at
    remove_column :system_node_module_versions, :live_at
    remove_column :system_node_module_versions, :retired_at
  end

  def down
    add_column :system_node_module_versions, :promotion_state, :string, default: "built", null: false
    add_column :system_node_module_versions, :staging_baked_at, :datetime
    add_column :system_node_module_versions, :blessed_at, :datetime
    add_column :system_node_module_versions, :live_at, :datetime
    add_column :system_node_module_versions, :retired_at, :datetime
    add_index :system_node_module_versions, :promotion_state
    add_check_constraint :system_node_module_versions,
                         "promotion_state::text = ANY (ARRAY['built'::character varying::text, " \
                         "'staging'::character varying::text, 'blessed'::character varying::text, " \
                         "'live'::character varying::text, 'retired'::character varying::text])",
                         name: "system_node_module_versions_promotion_state_check"
  end
end
