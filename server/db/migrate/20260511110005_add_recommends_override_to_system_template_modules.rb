# frozen_string_literal: true

class AddRecommendsOverrideToSystemTemplateModules < ActiveRecord::Migration[8.0]
  def change
    # Per-template override of a module's default Recommends inclusion.
    #
    # Shape (all keys optional; absence = inherit module defaults):
    #   { "excluded": ["iproute2"] }              → start from defaults, drop these
    #   { "included": ["ssl-cert-monitor"] }      → start from defaults, add these
    #   { "excluded": [...], "included": [...] }  → both; `included` wins on collision
    #   { "replace":  ["ssl-cert"] }              → ignore defaults entirely
    #
    # TemplateExpansionService merges this with PackageModuleLink.recommends_chosen
    # at NodeModuleAssignment-creation time to compute the effective closure for
    # a (template, node_module) pair.
    add_column :system_template_modules, :recommends_override, :jsonb,
      null: false, default: {}
  end
end
