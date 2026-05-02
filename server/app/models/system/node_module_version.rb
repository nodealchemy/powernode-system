# frozen_string_literal: true

module System
  # Stores historical versions of node modules for rollback capability
  # Each version captures the complete state of a module at a point in time
  class NodeModuleVersion < BaseRecord
    # === Constants ===
    # Promotion lifecycle states (Golden Eclipse M0.M).
    # built     — CI artifact landed, not yet exposed to runtime
    # staging   — eligible for staging fleet, soaking
    # blessed   — passed PromotionCriteria; can be assigned to live templates
    # live      — currently the canonical version for live deployments
    # retired   — superseded; kept for rollback/audit only
    PROMOTION_STATES = %w[built staging blessed live retired].freeze

    # === Associations ===
    belongs_to :node_module, class_name: 'System::NodeModule'
    belongs_to :created_by, class_name: 'User', optional: true
    has_many   :module_artifacts, class_name: 'System::ModuleArtifact', dependent: :destroy

    # === Validations ===
    validates :version_number, presence: true,
                               numericality: { only_integer: true, greater_than: 0 },
                               uniqueness: { scope: :node_module_id }
    validates :node_module, presence: true
    validates :promotion_state, inclusion: { in: PROMOTION_STATES }

    # === Scopes ===
    scope :ordered, -> { order(version_number: :desc) }
    scope :by_version, -> { order(version_number: :asc) }
    scope :latest_first, -> { order(version_number: :desc) }
    scope :with_data_file, -> { where.not(data_file_name: nil) }
    scope :built,    -> { where(promotion_state: 'built') }
    scope :staging,  -> { where(promotion_state: 'staging') }
    scope :blessed,  -> { where(promotion_state: 'blessed') }
    scope :live,     -> { where(promotion_state: 'live') }
    scope :retired,  -> { where(promotion_state: 'retired') }

    # === Callbacks ===
    before_validation :set_version_number, on: :create

    # === Methods ===

    # Check if this version has a data file attached
    def has_data_file?
      data_file_name.present?
    end

    # Check if this is the current version for its module
    def current?
      node_module&.current_version_id == id
    end

    # Check if this is the latest version
    def latest?
      node_module&.versions&.maximum(:version_number) == version_number
    end

    # Get the previous version
    def previous_version
      return nil unless node_module

      node_module.versions.where('version_number < ?', version_number).order(version_number: :desc).first
    end

    # Get the next version
    def next_version
      return nil unless node_module

      node_module.versions.where('version_number > ?', version_number).order(version_number: :asc).first
    end

    # Verify data file integrity using checksum
    def verify_checksum(file_content)
      return false unless data_checksum.present?

      Digest::SHA256.hexdigest(file_content) == data_checksum
    end

    # Generate summary of what changed in this version
    def change_summary
      changelog.presence || "Version #{version_number}"
    end

    # === Promotion lifecycle (Golden Eclipse M0.M) ===
    # Column-only state machine for now. Full AASM with PromotionCriteria
    # gates lands in M1 (mirroring Trading::PromotionCriteria pattern).

    PROMOTION_STATES.each do |state|
      define_method(:"#{state}?") { promotion_state == state }
    end

    # Promotes the version forward through the lifecycle. Stamps the
    # appropriate timestamp column. Raises on invalid transitions.
    PROMOTION_TRANSITIONS = {
      "built"   => %w[staging retired],
      "staging" => %w[blessed retired built],
      "blessed" => %w[live retired],
      "live"    => %w[retired],
      "retired" => %w[]
    }.freeze

    def promote_to!(target_state)
      target = target_state.to_s
      raise ArgumentError, "unknown state: #{target}" unless PROMOTION_STATES.include?(target)

      allowed = PROMOTION_TRANSITIONS.fetch(promotion_state, [])
      unless allowed.include?(target)
        raise InvalidTransition,
              "cannot transition from #{promotion_state} to #{target} (allowed: #{allowed.join(', ').presence || 'none'})"
      end

      stamp = case target
              when "staging" then :staging_baked_at
              when "blessed" then :blessed_at
              when "live"    then :live_at
              when "retired" then :retired_at
              end

      attrs = { promotion_state: target }
      attrs[stamp] = Time.current if stamp
      update!(attrs)
    end

    class InvalidTransition < StandardError; end

    private

    def set_version_number
      return if version_number.present?

      max_version = node_module&.versions&.maximum(:version_number) || 0
      self.version_number = max_version + 1
    end
  end
end
