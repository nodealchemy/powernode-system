# frozen_string_literal: true

module System
  class NodeModuleAssignment < BaseRecord
    include System::Base

    # === Associations ===
    belongs_to :node, class_name: "System::Node"
    belongs_to :node_module, class_name: "System::NodeModule"

    # Set when this assignment was produced by template-apply closure expansion.
    # Records which TemplateModule's recommends_override governed inclusion —
    # used by the on-node UI to explain "why is this here?" and by refresh
    # jobs to re-derive the closure on template changes. NULL for assignments
    # created outside the template-apply path.
    belongs_to :source_template_module,
               class_name: "System::TemplateModule",
               optional: true

    # Delegate account access through node
    delegate :account, to: :node
    delegate :account_id, to: :node

    # === Validations ===
    validates :node_id, uniqueness: { scope: :node_module_id, message: "already has this module assigned" }
    validates :priority, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    # === Scopes ===
    scope :enabled, -> { where(enabled: true) }
    scope :disabled, -> { where(enabled: false) }
    scope :by_priority, -> { order(priority: :desc) }
    scope :auto_resolved, -> { where(auto_resolved: true) }
    scope :explicit,      -> { where(auto_resolved: false) }

    # === Module-as-Skill auto-attach (Track F-4) ===
    # On attach (create), parse the module's manifest_yaml#skills and
    # register Ai::Skill rows. On detach (destroy), remove them. The
    # registrar is idempotent so re-creating an assignment is safe.
    after_commit :register_module_skills, on: :create
    after_commit :unregister_module_skills_if_last, on: :destroy

    # === Methods ===

    private

    def register_module_skills
      return unless defined?(::System::ModuleSkillRegistrar)
      ::System::ModuleSkillRegistrar.register_for_module!(node_module: node_module)
    rescue StandardError => e
      Rails.logger.warn("[NodeModuleAssignment] skill register failed: #{e.message}")
    end

    def unregister_module_skills_if_last
      # Only unregister when this was the last assignment of the module —
      # other assignments still need the skill rows.
      return unless defined?(::System::ModuleSkillRegistrar)
      return if ::System::NodeModuleAssignment.where(node_module_id: node_module_id).exists?
      ::System::ModuleSkillRegistrar.unregister_for_module!(node_module: node_module)
    rescue StandardError => e
      Rails.logger.warn("[NodeModuleAssignment] skill unregister failed: #{e.message}")
    end

    public

    # Spawn a dependant child module overriding the assigned subscription parent
    # for this (node, optional instance) pair. Legacy parity:
    # ~/Drive/Projects/powernode-server/app/models/node_module_subscription.rb:11-17.
    #
    # - With node_instance == nil: creates a config-variety child bound to the node
    # - With node_instance set:    creates an instance-variety child bound to (node, instance)
    #
    # The child inherits node_platform + category + account from the parent.
    # Idempotent: if a matching child already exists, returns it without
    # creating a duplicate.
    #
    # The child resolves its category through the parent's sibling-variety
    # chain (NodeModuleCategory#category_for_variety). When the parent's
    # category has wired-up sibling categories, the child gets a higher-
    # `position` category so its effective_priority sits above the parent's
    # in the union mount. When siblings are absent, the child falls back to
    # the parent's category — operators must then disambiguate via the
    # `priority` column directly.
    def create_dependant!(node_instance: nil)
      raise ArgumentError, "Cannot create dependant of an already-dependant module" if node_module.dependant?

      target_variety = node_instance.present? ? "instance" : "config"

      existing = ::System::NodeModule.find_by(
        parent_module_id: node_module_id,
        node_id: node_id,
        node_instance_id: node_instance&.id
      )
      return existing if existing

      resolved_category =
        if node_module.category
          node_module.category.category_for_variety(target_variety)
        end

      # When sibling categories aren't wired, fall back to priority + 1 so
      # the child is at least one tick above the parent within the same
      # category. When siblings ARE wired, the category multiplier handles
      # ordering and we leave priority alone for legibility.
      same_category = resolved_category.present? &&
                      resolved_category == node_module.category
      child_priority = if resolved_category.nil? || same_category
                         node_module.priority.to_i + 1
      else
                         node_module.priority.to_i
      end

      ::System::NodeModule.create!(
        account: node.account,
        node_platform: node_module.node_platform,
        category: resolved_category,
        parent_module: node_module,
        node: node,
        node_instance: node_instance,
        variety: target_variety,
        priority: child_priority,
        name: dependant_name(node_instance: node_instance),
        enabled: true
      )
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

    private

    # Generates a unique-per-account name for the dependant child. Uses
    # parent.name + "-for-" + (instance.name | node.name) for legibility,
    # plus a suffix to dodge the unique [account_id, name] constraint when
    # multiple instances of the same node spawn instance-variety children
    # with similar parent names.
    def dependant_name(node_instance:)
      target = node_instance&.name || node.name
      base = "#{node_module.name}-for-#{target}"
      candidate = base
      n = 1
      while ::System::NodeModule.exists?(account_id: node.account_id, name: candidate)
        candidate = "#{base}-#{n}"
        n += 1
      end
      candidate
    end
  end
end
