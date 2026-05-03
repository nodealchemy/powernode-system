# frozen_string_literal: true

module System
  class NodeModuleCategory < BaseRecord
    include System::Base

    # === Constants ===
    VARIETIES = %w[subscription config instance].freeze
    # Default `position` offsets so subscription < config < instance in
    # effective_priority. Each step is a full PRIORITY_CATEGORY_MULTIPLIER
    # bump on NodeModule (ensures children sit above parents in the union).
    DEFAULT_POSITION_OFFSETS = { "subscription" => 0, "config" => 1, "instance" => 2 }.freeze

    # === Associations ===
    belongs_to :account
    belongs_to :parent, class_name: "System::NodeModuleCategory", optional: true
    has_many :children, class_name: "System::NodeModuleCategory", foreign_key: :parent_id, dependent: :nullify
    has_many :node_modules, class_name: "System::NodeModule", foreign_key: :category_id, dependent: :nullify

    # Sibling-variety categories — populated only on subscription-variety rows.
    # Each subscription category points at its config + instance counterparts
    # so dependant module spawning can resolve the right higher-priority bucket.
    belongs_to :config_category,
               class_name: "System::NodeModuleCategory", optional: true
    belongs_to :instance_category,
               class_name: "System::NodeModuleCategory", optional: true

    # === Validations ===
    validates :name, presence: true, uniqueness: { scope: :account_id, case_sensitive: false }
    validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :variety, presence: true, inclusion: { in: VARIETIES }

    # === Scopes ===
    scope :enabled, -> { where(enabled: true) }
    scope :disabled, -> { where(enabled: false) }
    scope :public_categories, -> { where(public: true) }
    scope :private_categories, -> { where(public: false) }
    scope :root_categories, -> { where(parent_id: nil) }
    scope :by_position, -> { order(position: :asc) }
    scope :by_name, -> { order(name: :asc) }
    scope :subscription_variety, -> { where(variety: "subscription") }
    scope :config_variety,       -> { where(variety: "config") }
    scope :instance_variety,     -> { where(variety: "instance") }

    # === Class API ===

    # Creates a triplet of categories (subscription + config + instance)
    # with siblings pre-wired and ascending positions so the multiplier-based
    # effective_priority puts config above subscription, and instance above
    # config. Returns the subscription-variety category.
    #
    # Example:
    #   NodeModuleCategory.create_triplet!(account: a, base_name: "Web") =>
    #     three rows: "Web" (subscription, position N),
    #                 "Web (config)"   (config,    position N+1),
    #                 "Web (instance)" (instance,  position N+2),
    #     all linked: the subscription row's config_category_id and
    #     instance_category_id point at the appropriate sibling.
    def self.create_triplet!(account:, base_name:, base_position: 0,
                             enabled: true, public: false)
      transaction do
        config_cat = create!(
          account: account,
          name: "#{base_name} (config)",
          variety: "config",
          position: base_position + DEFAULT_POSITION_OFFSETS["config"],
          enabled: enabled,
          public: public
        )
        instance_cat = create!(
          account: account,
          name: "#{base_name} (instance)",
          variety: "instance",
          position: base_position + DEFAULT_POSITION_OFFSETS["instance"],
          enabled: enabled,
          public: public
        )
        create!(
          account: account,
          name: base_name,
          variety: "subscription",
          position: base_position + DEFAULT_POSITION_OFFSETS["subscription"],
          config_category: config_cat,
          instance_category: instance_cat,
          enabled: enabled,
          public: public
        )
      end
    end

    # === Methods ===
    def root?
      parent_id.nil?
    end

    def has_children?
      children.exists?
    end

    def depth
      return 0 if root?
      parent.depth + 1
    end

    def ancestors
      return [] if root?
      [ parent ] + parent.ancestors
    end

    def descendants
      children.flat_map { |child| [ child ] + child.descendants }
    end

    def module_count
      node_modules.count + descendants.sum(&:module_count)
    end

    VARIETIES.each do |v|
      define_method(:"#{v}_variety?") { variety == v }
    end

    # Resolves the appropriate sibling category given a desired child variety.
    # If this category is a subscription with siblings wired, returns the
    # corresponding sibling. Otherwise returns self (interim fallback).
    def category_for_variety(target_variety)
      case target_variety.to_s
      when "config"   then config_category   || self
      when "instance" then instance_category || self
      else self
      end
    end
  end
end
