# frozen_string_literal: true

module System
  class NodeInstance < BaseRecord
    include AASM

    # Constants
    VARIETIES = %w[cloud physical dynamic].freeze
    STATUSES = %w[pending provisioning starting running stopping stopped rebooting terminated error].freeze
    MAC_ADDRESS_REGEX = /\A([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})\z/

    # Slice 7 — pre-warmed instance pool membership.
    # NULL for non-pool instances (operator-owned, legacy path).
    POOL_STATES = %w[warming ready claimed draining errored].freeze

    # Phase O2 — OVS+OVN dual-profile network selector.
    # Picks which on-node BridgeApplier (and downstream CNI) the agent
    # runs. `lightweight` = Linux bridge only; `heavyweight` = OVS bridge
    # + OVN-controller + OVN-K8s CNI in later phases. Default is
    # `lightweight` because it imposes no daemon overhead and works on
    # every supported host (including Pi 4 ≤4GB / Pi Zero 2W). Operator
    # promotes to `heavyweight` deliberately, or autonomy/provisioning
    # consults #suggest_network_profile and acts on the recommendation.
    NETWORK_PROFILES = %w[lightweight heavyweight].freeze

    # Memory floor (MB) under which the heavyweight profile is unsafe.
    # Sourced from the OVS+OVN footprint analysis (~150-200MB RAM for
    # the three additional daemons + headroom for the host kernel).
    HEAVYWEIGHT_MIN_MEMORY_MB = 4096

    # Pi 4 needs the 8GB SKU specifically — the 1/2/4GB SKUs cannot run
    # OVS+OVN+OVN-K8s reliably alongside K3s and the other workload pods.
    HEAVYWEIGHT_PI4_MIN_MEMORY_MB = 8192

    # Hardware-model hints persisted in `config["hardware_model"]` (or
    # discovery DMI metadata) that the suggester recognises. The full
    # list is intentionally narrow — anything outside the known-capable
    # set falls through to the safe `lightweight` default.
    HEAVYWEIGHT_PI_MODELS = %w[raspberry_pi_5 rpi5 pi5].freeze
    PI4_HARDWARE_MODELS   = %w[raspberry_pi_4 rpi4 pi4].freeze

    # Encryption for sensitive fields
    encrypts :key

    # Associations
    belongs_to :node, class_name: "System::Node"
    belongs_to :provider_region, class_name: "System::ProviderRegion", optional: true
    belongs_to :provider_instance_type, class_name: "System::ProviderInstanceType", optional: true
    # Slice 7 — optional pool membership.
    belongs_to :instance_pool,
               class_name: "System::InstancePool",
               optional: true

    # Mount point associations (Release 3)
    has_many :instance_mount_points, class_name: "System::InstanceMountPoint", dependent: :destroy
    has_many :mount_points, through: :instance_mount_points, source: :mount_point

    # Task associations (Release 4)
    has_many :tasks, class_name: "System::Task", as: :operable, dependent: :destroy

    # Volume associations (Release 4)
    has_many :provider_volumes, class_name: "System::ProviderVolume"

    # Delegations
    delegate :account, :account_id, to: :node

    # Validations
    validates :name, presence: true, uniqueness: { scope: :node_id }
    validates :variety, presence: true, inclusion: { in: VARIETIES }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :network_profile, presence: true, inclusion: { in: NETWORK_PROFILES }
    validates :mac_address, format: { with: MAC_ADDRESS_REGEX, message: "must be a valid MAC address" }, allow_nil: true
    validates :latitude, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }, allow_nil: true
    validates :longitude, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }, allow_nil: true

    # Config accessors. Virtual attributes stored as JSONB keys on `config`
    # so callers can use the dot-accessor (`instance.cloud_instance_id`) while
    # the data persists in the same JSONB blob. Other config keys
    # (ip_allocation_id, ip_association_id, netboot.enabled, ipmi.*) use
    # the explicit `config.merge` pattern at the call site and don't need
    # accessor declarations.
    store_accessor :config, :cloud_instance_id, :admin_user

    # === State machine (AASM — platform standard) ===
    # Two-phase transitions: control actions ("start", "stop", "reboot",
    # "terminate") move into a transitional state; the worker runtime
    # finalizes via "mark_running", "mark_stopped", "mark_terminated",
    # "mark_errored". Keeps the existing UI-visible state vocabulary while
    # making transitions enforceable through the platform-standard pattern.
    aasm column: :status, whiny_transitions: true do
      state :pending, initial: true
      state :provisioning
      state :starting
      state :running
      state :stopping
      state :stopped
      state :rebooting
      state :terminated
      state :error

      # Operator-initiated transitions (intermediate states)
      event :start do
        transitions from: [ :stopped, :error ], to: :starting
      end

      event :stop do
        transitions from: [ :running, :starting ], to: :stopping
      end

      event :reboot do
        transitions from: :running, to: :rebooting
      end

      event :terminate do
        transitions from: [ :stopped, :running, :error ], to: :terminated
      end

      # Worker runtime finalizers
      event :mark_provisioning do
        transitions from: :pending, to: :provisioning
      end

      event :mark_running do
        transitions from: [ :starting, :rebooting, :provisioning, :pending ], to: :running
      end

      event :mark_stopped do
        transitions from: [ :stopping, :running ], to: :stopped
      end

      event :mark_terminated do
        transitions from: [ :terminated, :stopped, :running, :error ], to: :terminated
      end

      event :mark_errored do
        transitions from: [ :pending, :provisioning, :starting, :running, :stopping, :rebooting ], to: :error
      end
    end

    # M4 audit trail — `prepend` so our overrides take precedence over the
    # bang methods AASM defines directly on the class. `super` inside our
    # overrides resolves to AASM's implementation, which performs the
    # actual state transition; we then write the audit row.
    prepend System::LifecycleAuditable

    # Scopes
    scope :cloud, -> { where(variety: "cloud") }
    scope :physical, -> { where(variety: "physical") }
    scope :dynamic, -> { where(variety: "dynamic") }
    scope :pending, -> { where(status: "pending") }
    scope :provisioning, -> { where(status: "provisioning") }
    scope :running, -> { where(status: "running") }
    scope :stopped, -> { where(status: "stopped") }
    scope :terminated, -> { where(status: "terminated") }
    scope :errored, -> { where(status: "error") }
    scope :active, -> { where(status: %w[pending provisioning running stopped]) }

    # Phase O2 — network profile scopes (used by FleetAutonomyService and
    # the heavyweight-host dashboards to filter the fleet by which
    # BridgeApplier the agent runs).
    scope :lightweight_profile, -> { where(network_profile: "lightweight") }
    scope :heavyweight_profile, -> { where(network_profile: "heavyweight") }

    # Slice 7 — pool membership scopes
    scope :pool_warming, -> { where(pool_state: "warming") }
    scope :pool_ready, -> { where(pool_state: "ready") }
    scope :pool_claimed, -> { where(pool_state: "claimed") }
    scope :pool_draining, -> { where(pool_state: "draining") }
    scope :pool_errored, -> { where(pool_state: "errored") }
    scope :in_any_pool, -> { where.not(instance_pool_id: nil) }
    scope :not_in_pool, -> { where(instance_pool_id: nil) }

    # Variety predicates
    VARIETIES.each do |variety_name|
      define_method("#{variety_name}?") { variety == variety_name }
    end

    # Slice 7 — pool state predicates
    POOL_STATES.each do |pool_state_name|
      define_method("pool_#{pool_state_name}?") { pool_state == pool_state_name }
    end

    def in_pool?
      instance_pool_id.present?
    end

    # Idempotent transition: warming → ready (called from provisioning
    # success callback / heartbeat success). Returns true if the
    # transition succeeded, false if state didn't allow it (e.g. already
    # ready, claimed, draining, etc.).
    def mark_pool_ready!
      return false unless in_pool?
      return false unless pool_state == "warming"
      update!(pool_state: "ready")
      true
    end

    # Idempotent transition: any pool state → errored. Reaper recycles
    # errored members into terminated state on the next tick.
    def mark_pool_errored!
      return false unless in_pool?
      return false if %w[claimed draining].include?(pool_state)
      update!(pool_state: "errored")
      true
    end

    # Pool slot duration accessors used by the reaper to decide
    # health-check + recycling cadence.
    def pool_warming_duration
      return nil unless pool_warming_started_at
      (Time.current - pool_warming_started_at).to_i
    end

    def pool_idle_duration
      return nil unless pool_state == "ready" && pool_warming_started_at
      (Time.current - pool_warming_started_at).to_i
    end

    # Check if instance is active (not terminated or error)
    def active?
      !terminated? && !error?
    end

    # === Lifecycle predicates ===
    # Operator-friendly aliases for AASM `may_*?` guards. They answer the
    # question "is this control action available right now?" given the
    # instance's current AASM state. Used by UI buttons and integration
    # specs that read more naturally as `instance.can_stop?` than
    # `instance.may_stop?`.
    def can_start?
      may_start?
    end

    def can_stop?
      may_stop?
    end

    def can_reboot?
      may_reboot?
    end

    def can_terminate?
      may_terminate?
    end

    # === Geolocation Methods ===
    def has_coordinates?
      latitude.present? && longitude.present?
    end

    def coordinates
      return nil unless has_coordinates?
      { latitude: latitude, longitude: longitude }
    end

    def set_coordinates!(lat, lng)
      update!(latitude: lat, longitude: lng)
    end

    # === Network Methods ===
    def has_mac_address?
      mac_address.present?
    end

    def normalized_mac_address
      return nil unless has_mac_address?
      mac_address.upcase.gsub("-", ":")
    end

    def netboot_enabled?
      physical? && private_netboot == true
    end

    def enable_netboot!
      return false unless physical?
      update!(private_netboot: true)
    end

    def disable_netboot!
      update!(private_netboot: false)
    end

    # === Network profile suggestion (Phase O2) ===
    #
    # Pure function — reads only this row's hardware fields and returns
    # the recommended `network_profile` value. Does NOT mutate state and
    # does NOT consult the persisted `network_profile` column (callers
    # already know what's persisted; this answers "what *should* it be").
    #
    # Operators / FleetAutonomyService / the provisioning service call
    # this to decide whether to promote a host to the heavyweight stack.
    # The persisted column is the source of truth — this is advisory.
    #
    # Recommendation rules (mirror Part 7 of the dual-profile plan):
    #   1. amd64 with ≥4GB RAM → heavyweight
    #   2. arm64 + Pi 5 hardware hint (any RAM) → heavyweight
    #   3. arm64 + Pi 4 hardware hint with ≥8GB RAM → heavyweight
    #   4. Anything else (Pi 4 ≤4GB, Pi Zero 2W, Alpine aarch64,
    #      hardware fields not available, etc.) → lightweight
    #
    # The "hardware fields not available" branch is the safety net: when
    # we can't prove the host has headroom for the OVS+OVN daemons, we
    # default to lightweight because the lightweight profile works on
    # every supported host.
    def suggest_network_profile
      arch = (architecture || "").downcase
      mb   = available_memory_mb
      hw   = hardware_model_hint

      case arch
      when "amd64", "x86_64"
        return "heavyweight" if mb && mb >= HEAVYWEIGHT_MIN_MEMORY_MB
      when "arm64", "aarch64"
        return "heavyweight" if HEAVYWEIGHT_PI_MODELS.include?(hw)
        if PI4_HARDWARE_MODELS.include?(hw) && mb && mb >= HEAVYWEIGHT_PI4_MIN_MEMORY_MB
          return "heavyweight"
        end
      end

      "lightweight"
    end

    # === Runtime telemetry (Golden Eclipse M0.M) ===
    # Used by powernode-agent heartbeat path (M0.O / M0.P / M2). Maintains
    # last_heartbeat_at, agent_version, boot_id, and the running_module_digests
    # snapshot so FleetAutonomyService (M7) can detect drift.

    HEARTBEAT_STALE_AFTER = 3.minutes

    has_many :node_certificates, class_name: "System::NodeCertificate", dependent: :destroy
    belongs_to :enrollment_token, class_name: "System::BootstrapToken", optional: true

    def stale_heartbeat?
      return true if last_heartbeat_at.nil?

      last_heartbeat_at < HEARTBEAT_STALE_AFTER.ago
    end

    # Records a heartbeat from the on-node powernode-agent. The :module_digests
    # parameter is a hash of { module_id => oci_digest } captured by the agent.
    def record_heartbeat!(agent_version:, boot_id:, module_digests: {}, architecture: nil)
      attrs = {
        last_heartbeat_at: Time.current,
        agent_version: agent_version,
        boot_id: boot_id,
        running_module_digests: (module_digests || {}).to_h
      }
      attrs[:architecture] = architecture if architecture.present?
      update!(attrs)
    end

    # The currently active mTLS cert for this instance (most recently issued,
    # not revoked). Nil if the instance has never enrolled.
    def active_certificate
      node_certificates.active.order(not_before: :desc).first
    end

    # === Physical-device claim helpers (plan wondrous-yawning-anchor.md) ===
    # claimed? — true once an operator has confirmed the device's identity
    # via the Unclaimed Devices UI. The device's next /claim poll receives
    # a bootstrap token at that point.
    def claimed?
      claimed_at.present? && claim_code.present?
    end

    # awaiting_claim? — true for physical instances that exist in the
    # platform but haven't yet been bound to a real device. UI surfaces a
    # "waiting for device to come online" banner when this is true.
    def awaiting_claim?
      physical? && claimed_at.nil?
    end

    private

    # Best-effort memory lookup used by #suggest_network_profile. Reads
    # from provider_instance_type when the instance has one (cloud
    # variety / templated physical), then falls back to a
    # `config["memory_mb"]` hint that the agent can report at heartbeat
    # time. Returns nil when nothing is known — callers MUST treat nil
    # as "unknown, assume too small" so the suggester defaults to the
    # safe `lightweight` profile.
    def available_memory_mb
      type_mb = provider_instance_type&.memory_mb
      return type_mb if type_mb

      raw = config && config["memory_mb"]
      return nil if raw.nil?
      Integer(raw)
    rescue ArgumentError, TypeError
      nil
    end

    # Best-effort hardware-model lookup, normalised to a lowercase
    # snake_case token. Reads from `config["hardware_model"]` (or the
    # legacy `config["board_model"]` alias) — operator-asserted at row
    # creation or filled in by the on-node agent's DMI scrape. Returns
    # nil when nothing is known — the suggester then falls through to
    # lightweight via the safe default. The `discovered_dmi_uuid`
    # column is intentionally skipped here (DMI UUID is opaque and not
    # a model discriminator).
    def hardware_model_hint
      raw = config && (config["hardware_model"] || config["board_model"])
      return nil if raw.nil? || raw.to_s.strip.empty?
      raw.to_s.downcase.strip.gsub(/[\s-]+/, "_")
    end
  end
end
