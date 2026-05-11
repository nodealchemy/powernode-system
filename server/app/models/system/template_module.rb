# frozen_string_literal: true

module System
  class TemplateModule < BaseRecord
    include System::Base

    # === Associations ===
    belongs_to :node_template, class_name: "System::NodeTemplate"
    belongs_to :node_module, class_name: "System::NodeModule"

    # Delegate account access through template
    delegate :account, to: :node_template
    delegate :account_id, to: :node_template

    # === Validations ===
    validates :node_template_id, uniqueness: { scope: :node_module_id, message: "already has this module" }
    validates :priority, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    # === Scopes ===
    scope :enabled, -> { where(enabled: true) }
    scope :disabled, -> { where(enabled: false) }
    scope :by_priority, -> { order(priority: :desc) }

    # === Methods ===
    def merged_config
      (node_module.config || {}).deep_merge(config || {})
    end

    def module_name
      node_module&.name
    end

    def module_variety
      node_module&.variety
    end

    def template_name
      node_template&.name
    end

    # Computes the effective set of Recommends package names to pull in when
    # this TemplateModule expands into NodeModuleAssignments. Algorithm:
    #
    # 1. Defaults from the module's PackageModuleLink.recommends_chosen
    #    (empty array if the module isn't package-sourced)
    # 2. If recommends_override has "replace" → use that exact list, ignore defaults
    # 3. Else apply "excluded" subtraction then "included" addition
    #
    # Returns a Set<String> of package names. Used by TemplateExpansionService.
    def effective_recommends_set
      override = (recommends_override || {}).with_indifferent_access

      if override["replace"].is_a?(Array)
        return override["replace"].map(&:to_s).to_set
      end

      defaults = Array(node_module&.package_module_link&.recommends_chosen).map(&:to_s)
      result = defaults.to_set

      Array(override["excluded"]).each { |pkg| result.delete(pkg.to_s) }
      Array(override["included"]).each { |pkg| result.add(pkg.to_s) }
      result
    end
  end
end
