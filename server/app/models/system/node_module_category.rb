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

    # Canonical layering taxonomy for the platform's own module manifests
    # (extensions/system/modules/<name>/manifest.yaml `category:` field).
    # Keyed by the slug a manifest declares; ascending base_position is the
    # bottom-to-top overlay-stack order (see NodeModule#effective_priority —
    # higher category.position wins the union). db/seeds/powernode_platform_
    # categories.rb is the primary creator of these rows (one triplet per
    # entry, per account); ManifestImportService#apply_to_module resolves a
    # manifest's declared `category:` slug against this same table and
    # self-heals (creates the triplet) if the categories seed hasn't run yet.
    #
    # "workloads" is the fallback bucket for modules with no manifest
    # `category:` (forward-compat) and for System::PackageModuleMaterializer's
    # on-demand/operator-materialized modules when no category_id is given.
    #
    # campaign 019f6084 — replaces the single "Powernode Platform"
    # position-500 catch-all that dumped all 20 platform modules into one
    # category, tying every module's effective_priority and leaving overlay
    # order tie-broken by name (nondeterministic from the operator's POV).
    PLATFORM_TAXONOMY = {
      "system-base"      => { base_name: "System Base",       base_position: 120 },
      "base-os"          => { base_name: "Base OS",            base_position: 150 },
      "language-runtime" => { base_name: "Language Runtime",   base_position: 250 },
      "data-plane"       => { base_name: "Data Plane",         base_position: 300 },
      "storage-guest"    => { base_name: "Storage & Guest",    base_position: 320 },
      "networking-proxy" => { base_name: "Networking / Proxy", base_position: 350 },
      "observability"    => { base_name: "Observability",      base_position: 400 },
      "build-dev"        => { base_name: "Build & Dev",        base_position: 450 },
      "platform-apps"    => { base_name: "Platform Apps",      base_position: 550 },
      "workloads"        => { base_name: "Workloads",          base_position: 560 }
    }.freeze

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

    # Resolves the subscription-variety category for a PLATFORM_TAXONOMY
    # slug, creating the account's triplet on first use (self-healing —
    # db/seeds/powernode_platform_categories.rb is the primary creator, but
    # any caller that runs before that seed, e.g. an early account or a CI
    # manifest publish, still lands the module in the right bucket instead
    # of failing). Returns nil for an unrecognized slug (caller's manifest
    # validation is expected to have already rejected it).
    def self.for_platform_slug!(account:, slug:)
      taxonomy = PLATFORM_TAXONOMY[slug.to_s]
      return nil unless taxonomy

      find_by(account: account, name: taxonomy[:base_name], variety: "subscription") ||
        create_triplet!(
          account: account,
          base_name: taxonomy[:base_name],
          base_position: taxonomy[:base_position],
          enabled: true,
          public: false
        )
    end

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
