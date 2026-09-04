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
  #      pool_state="warming". The standard enrollment flow runs
  #      unchanged; there is no after_save callback — promotion is
  #      heartbeat-driven: once the on-node agent enrolls and sends its
  #      first successful heartbeat, StatusController#heartbeat calls
  #      NodeInstance#promote_pool_ready! (wraps mark_pool_ready!), which
  #      flips pool_state to "ready" and emits a "system.pool.member_ready"
  #      FleetEvent. A member that never enrolls (e.g. a provider adapter
  #      that never staged enrollment identity) never heartbeats and so
  #      never promotes — it stays "warming" until the reaper's
  #      warming_timeout recycle picks it up.
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
  #      keep running until normally terminated. The reaper keeps
  #      RECYCLING a draining pool — that is what empties it; only the
  #      top-up stops (replenish! refuses any non-active pool,
  #      IMP-cb2da06a384b). target_size is left standing so
  #      status -> "active" warms the pool back to the size it had.
  class InstancePool < BaseRecord
    include System::Base

    # No `persistent` — deliberately. A pool exists to be warmed, claimed and
    # replenished; a machine you intend to keep forever is not pool stock.
    #
    # This is the ONLY lifecycle_class column left. system_nodes used to carry
    # one (persistent|ephemeral|spot) that provision_warming_member! copied
    # this value onto; IMP-19843220ac68 retired that copy and IMP-f2a7a729d39b
    # dropped the column, so the pool row is the authoritative — and sole —
    # holder of a machine's class. A member reaches it through
    # config["instance_pool_id"]. system_node_instances.lease_class is a
    # different axis (lease provenance), not a lifecycle class. Pinned by
    # spec/models/system/lifecycle_class_value_space_spec.rb.
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
    # ACTIVE ONLY, and the name is the point: this must name exactly the set
    # InstancePoolService#replenish! accepts. It used to read
    # %w[active draining] — the reaper's LISTING set, which is a different
    # question (a draining pool is still listed, because recycling is what
    # empties it) and which made the scope assert the very thing
    # IMP-cb2da06a384b fixed: that a draining pool gets topped up.
    #
    # Pinned against replenish!'s guard, status by status, in
    # spec/services/system/instance_pool_service_spec.rb.
    scope :replenishable, -> { where(status: "active") }
    scope :by_oldest_replenish, -> { order(Arel.sql("last_replenished_at NULLS FIRST")) }
    scope :for_account, ->(account) { where(account_id: account.is_a?(::Account) ? account.id : account) }
    # GPU-bearing pools — a pool's accelerator capability derives from its bound
    # provider_instance_type SKU (audit P6). Optionally narrow by gpu_type + a
    # minimum GPU count to schedule a GPU workload onto a pre-warmed pool.
    scope :with_gpu, -> { joins(:provider_instance_type).where("system_provider_instance_types.gpu_count > 0") }
    scope :by_gpu, ->(gpu_type = nil, min_count: 1) {
      rel = joins(:provider_instance_type).where("system_provider_instance_types.gpu_count >= ?", min_count)
      gpu_type.present? ? rel.where("LOWER(system_provider_instance_types.gpu_type) = LOWER(?)", gpu_type) : rel
    }

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
      [ target_size - (ready_count + warming_count), 0 ].max
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

    # A nil size is already reported by the numericality validators above, and
    # comparing one here RAISES rather than adding an error — `5 < nil` is an
    # ArgumentError, not false. A `validate` method must not raise, so the
    # guard belongs here and not at any one call site. A bare cardinal here
    # has no oracle and this comment has already carried a wrong one twice, so
    # it is stated as a census with a location instead: MANY sites reach this
    # validator — the gated create's unsaved candidate, CreatePool's `create!`,
    # InstancePoolsController#update's inline `update!` and its gate_update!
    # pre-validation, UpdatePool's `update!` at approval time, destroy's
    # on_proceed, SystemFleetTool's create/update, Gitops::ApplyService's
    # create/update, CiRunnerLeaseService, InstanceStatusSensor and two seeds.
    # spec/lint/instance_pool_replenish_gating_spec.rb (CEILING_WRITERS) holds
    # the enumerable half of that by file and count; this comment says only
    # that there is no single call site to put the guard on.
    #
    # It was latent on only one of them. #update's INLINE arm has been
    # answering 500 for `"target_size": null` since that action was written —
    # #update permits all three sizes and rescues only RecordInvalid, and
    # nothing rescues ArgumentError. (Still the inline arm after
    # IMP-24daa05e7a22: a null size is not an increase, so it never reaches
    # the ceiling gate.) On the gated create the raise was hidden
    # instead (Ai::AutonomyGate#evaluate rescues StandardError) until
    # IMP-785d60f5ec3e put `candidate.valid?` in front of the gate, at which
    # point the same payload answered 500 there too. This guard repairs both.
    # Bail out and let numericality speak.
    def max_gte_target_gte_min
      return if [ max_size, target_size, min_size ].any?(&:nil?)

      if max_size < target_size
        errors.add(:max_size, "must be >= target_size")
      end
      if target_size < min_size
        errors.add(:target_size, "must be >= min_size")
      end
    end
  end
end
