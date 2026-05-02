# frozen_string_literal: true

# Golden Eclipse M0 polish — restore the legacy NodeModuleCategory variety
# hierarchy so dependant modules pick up properly higher-priority sibling
# categories instead of relying on the interim "priority + 1" bump from M0.J.
#
# A "subscription" category names a publishable module type. Its sibling
# config_category and instance_category point at higher-`position` categories
# whose multiplier-driven effective_priority sits above the parent's, putting
# config/instance dependant children above their subscription parent in the
# union mount.
#
# Reference: ~/Drive/Projects/powernode-server/app/models/node_module.rb#node_module_category
# (lines 165-182 — orig_node_module_category fallthrough to parent_module.category.config_category).
class AddVarietyAndSiblingsToNodeModuleCategories < ActiveRecord::Migration[8.0]
  def change
    change_table :system_node_module_categories, bulk: true do |t|
      t.string :variety, null: false, default: "subscription"
      t.references :config_category,
                   type: :uuid,
                   foreign_key: { to_table: :system_node_module_categories }
      t.references :instance_category,
                   type: :uuid,
                   foreign_key: { to_table: :system_node_module_categories }
    end

    add_check_constraint :system_node_module_categories,
                         "variety IN ('subscription', 'config', 'instance')",
                         name: "system_node_module_categories_variety_check"

    add_index :system_node_module_categories, :variety
  end
end
