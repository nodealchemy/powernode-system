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

    # The `priority` a caller supplied, as an Integer — or a refusal.
    #
    # Both write surfaces used `params[:priority].to_i`, which fails two ways:
    # a Hash or Array has no #to_i, so malformed JSON raised NoMethodError and
    # surfaced as a 500 instead of a validation error; and "abc".to_i is 0
    # SILENTLY. The second is the worse one. priority is what orders modules
    # within a composition (`by_priority`, DependencyResolutionService's
    # order_by_priority), and 0 is the lowest, so a typo'd priority did not
    # fail — it quietly changed which module wins a conflict.
    #
    # nil is deliberately NOT coerced. Both callers drop absent keys so a
    # partial update touches only what it names, and the column default (0)
    # applies at INSERT only — turning a missing key into 0 would demote an
    # existing join to lowest priority on an unrelated edit. nil in, nil out.
    #
    # Integer-looking strings are accepted: HTTP and JSON clients legitimately
    # send "7". Everything else is refused, INCLUDING Floats — truncating 2.7
    # to 2 is the same silent wrong answer as "abc" becoming 0.
    #
    # RANGE stays the model's job: a negative parses here and is then rejected
    # by the numericality validation above with its own message, so there is
    # one owner per concern. Phrasing mirrors
    # System::Gitops::DesiredStateValidator, this extension's existing answer
    # to the same question. (IMP-280a5abf09dc)
    def self.coerce_priority!(value)
      return nil if value.nil?
      return value if value.is_a?(Integer)

      return value.strip.to_i if value.is_a?(String) && value.strip.match?(/\A[+-]?\d+\z/)

      detail = value.is_a?(String) ? value.truncate(40).inspect : value.class
      raise ArgumentError, "priority must be an integer (got #{detail})"
    end

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
