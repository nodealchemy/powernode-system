# frozen_string_literal: true

module System
  # Slice 7 — pre-warmed instance pool.
  #
  # Models an operator-configured pool of pre-provisioned NodeInstances
  # kept warm (provisioned + enrolled + module-attached + daemon-ready)
  # so subsequent operator requests for ephemeral instances pop in <30s
  # instead of the cold 5-10min provision path.
  #
  # Lifecycle:
  #   1. Operator creates pool via system_create_instance_pool MCP action
  #      (or REST endpoint). Sets target_size, min_size, max_size, and
  #      either pins region/instance_type directly or relies on the
  #      pool's node_template defaults.
  #   2. Periodic reaper job (worker/system/instance_pool_replenisher_job)
  #      checks each active pool every 60s. If ready_count < target_size,
  #      provisions new NodeInstance(s) bound to this pool with
  #      pool_state="warming". The standard enrollment + module-attach
  #      flow runs unchanged; once the instance reaches status="running"
  #      AND its modules are all attached, an after_save callback flips
  #      pool_state to "ready".
  #   3. Operator (or AI agent) calls acquire! to pull a ready instance.
  #      Atomic UPDATE with row lock claims the oldest "ready" member,
  #      sets pool_state="claimed" + pool_acquired_at=NOW. The instance
  #      is now operator-owned; reaper provisions a replacement.
  #   4. When operator decommissions (or auto-expires), the standard
  #      terminate flow runs. pool_state stays "claimed" through
  #      termination so post-mortem queries can still trace pool
  #      membership.
  #   5. Operator-driven drain! sets pool.status="draining". Reaper
  #      stops replenishing, terminates ready members. Claimed members
  #      keep running until normally terminated.
  class InstancePool < BaseRecord
    include System::Base

    LIFECYCLE_CLASSES = %w[ephemeral spot].freeze
    STATUSES = %w[active paused draining archived].freeze

    # === Associations ===
    belongs_to :account
    belongs_to :node_template, class_name: "System::NodeTemplate"
    belongs_to :provider_region,
               class_name: "System::ProviderRegion",
               optional: true
    belongs_to :provider_instance_type,
               class_name: "System::ProviderInstanceType",
               optional: true

    has_many :node_instances,
             class_name: "System::NodeInstance",
             foreign_key: :instance_pool_id,
             dependent: :nullify

    # === Validations ===
    validates :name, presence: true, uniqueness: { scope: :account_id, case_sensitive: false }
    validates :target_size, :min_size, :max_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :lifecycle_class, presence: true, inclusion: { in: LIFECYCLE_CLASSES }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validate :max_gte_target_gte_min

    # === Scopes ===
    scope :active, -> { where(status: "active") }
    scope :paused, -> { where(status: "paused") }
    scope :draining, -> { where(status: "draining") }
    scope :replenishable, -> { where(status: %w[active draining]) }
    scope :by_oldest_replenish, -> { order(Arel.sql("last_replenished_at NULLS FIRST")) }
    scope :for_account, ->(account) { where(account_id: account.is_a?(::Account) ? account.id : account) }

    # === Attributes ===
    attribute :metadata, :json, default: -> { {} }

    # === Instance methods — counts + diagnostics ===

    def ready_count
      node_instances.where(pool_state: "ready").count
    end

    def warming_count
      node_instances.where(pool_state: "warming").count
    end

    def claimed_count
      node_instances.where(pool_state: "claimed").count
    end

    def errored_count
      node_instances.where(pool_state: "errored").count
    end

    # Active pool members (warming + ready + claimed) excluding draining
    # and errored — those are pending cleanup.
    def active_member_count
      node_instances.where(pool_state: %w[warming ready claimed]).count
    end

    # Deficit = how many new instances the reaper should provision.
    # Computed against (warming + ready) since claimed instances don't
    # count toward "available capacity".
    def deficit
      [target_size - (ready_count + warming_count), 0].max
    end

    # Surplus = how many ready instances the reaper should terminate
    # to bring the pool down to target_size. Negative = no surplus.
    def surplus
      ready_count - target_size
    end

    # === State machine helpers ===

    def active?
      status == "active"
    end

    def paused?
      status == "paused"
    end

    def draining?
      status == "draining"
    end

    def archived?
      status == "archived"
    end

    # === Bulk operations on members ===

    def ready_members
      node_instances.where(pool_state: "ready")
                    .order(Arel.sql("pool_warming_started_at NULLS LAST"))
    end

    def warming_members
      node_instances.where(pool_state: "warming")
    end

    def claimed_members
      node_instances.where(pool_state: "claimed")
    end

    def errored_members
      node_instances.where(pool_state: "errored")
    end

    def to_summary
      {
        id: id,
        name: name,
        status: status,
        lifecycle_class: lifecycle_class,
        target_size: target_size,
        min_size: min_size,
        max_size: max_size,
        ready_count: ready_count,
        warming_count: warming_count,
        claimed_count: claimed_count,
        errored_count: errored_count,
        deficit: deficit,
        last_replenished_at: last_replenished_at&.utc&.iso8601
      }
    end

    private

    def max_gte_target_gte_min
      if max_size < target_size
        errors.add(:max_size, "must be >= target_size")
      end
      if target_size < min_size
        errors.add(:target_size, "must be >= min_size")
      end
    end
  end
end
