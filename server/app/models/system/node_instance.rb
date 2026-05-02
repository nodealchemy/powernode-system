# frozen_string_literal: true

module System
  class NodeInstance < BaseRecord
    include AASM

    # Constants
    VARIETIES = %w[cloud physical dynamic].freeze
    STATUSES = %w[pending provisioning starting running stopping stopped rebooting terminated error].freeze
    MAC_ADDRESS_REGEX = /\A([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})\z/

    # Encryption for sensitive fields
    encrypts :key

    # Associations
    belongs_to :node, class_name: 'System::Node'
    belongs_to :provider_region, class_name: 'System::ProviderRegion', optional: true
    belongs_to :provider_instance_type, class_name: 'System::ProviderInstanceType', optional: true

    # Mount point associations (Release 3)
    has_many :instance_mount_points, class_name: 'System::InstanceMountPoint', dependent: :destroy
    has_many :mount_points, through: :instance_mount_points, source: :mount_point

    # Task associations (Release 4)
    has_many :tasks, class_name: 'System::Task', as: :operable, dependent: :destroy

    # Volume associations (Release 4)
    has_many :provider_volumes, class_name: 'System::ProviderVolume'

    # Delegations
    delegate :account, :account_id, to: :node

    # Validations
    validates :name, presence: true, uniqueness: { scope: :node_id }
    validates :variety, presence: true, inclusion: { in: VARIETIES }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :mac_address, format: { with: MAC_ADDRESS_REGEX, message: 'must be a valid MAC address' }, allow_nil: true
    validates :latitude, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }, allow_nil: true
    validates :longitude, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }, allow_nil: true

    # Config accessors. Virtual attributes stored as JSONB keys on `config`
    # so callers can use the dot-accessor (`instance.cloud_instance_id`) while
    # the data persists in the same JSONB blob. Other config keys
    # (ip_allocation_id, ip_association_id, netboot.enabled, ipmi.*) use
    # the explicit `config.merge` pattern at the call site and don't need
    # accessor declarations.
    store_accessor :config, :cloud_instance_id

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
        transitions from: [:stopped, :error], to: :starting
      end

      event :stop do
        transitions from: [:running, :starting], to: :stopping
      end

      event :reboot do
        transitions from: :running, to: :rebooting
      end

      event :terminate do
        transitions from: [:stopped, :running, :error], to: :terminated
      end

      # Worker runtime finalizers
      event :mark_provisioning do
        transitions from: :pending, to: :provisioning
      end

      event :mark_running do
        transitions from: [:starting, :rebooting, :provisioning, :pending], to: :running
      end

      event :mark_stopped do
        transitions from: [:stopping, :running], to: :stopped
      end

      event :mark_terminated do
        transitions from: [:terminated, :stopped, :running, :error], to: :terminated
      end

      event :mark_errored do
        transitions from: [:pending, :provisioning, :starting, :running, :stopping, :rebooting], to: :error
      end
    end

    # Scopes
    scope :cloud, -> { where(variety: 'cloud') }
    scope :physical, -> { where(variety: 'physical') }
    scope :dynamic, -> { where(variety: 'dynamic') }
    scope :pending, -> { where(status: 'pending') }
    scope :provisioning, -> { where(status: 'provisioning') }
    scope :running, -> { where(status: 'running') }
    scope :stopped, -> { where(status: 'stopped') }
    scope :terminated, -> { where(status: 'terminated') }
    scope :errored, -> { where(status: 'error') }
    scope :active, -> { where(status: %w[pending provisioning running stopped]) }

    # Variety predicates
    VARIETIES.each do |variety_name|
      define_method("#{variety_name}?") { variety == variety_name }
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
      mac_address.upcase.gsub('-', ':')
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

    # === Runtime telemetry (Golden Eclipse M0.M) ===
    # Used by ipn-agent heartbeat path (M0.O / M0.P / M2). Maintains
    # last_heartbeat_at, agent_version, boot_id, and the running_module_digests
    # snapshot so FleetAutonomyService (M7) can detect drift.

    HEARTBEAT_STALE_AFTER = 3.minutes

    has_many :node_certificates, class_name: 'System::NodeCertificate', dependent: :destroy
    belongs_to :enrollment_token, class_name: 'System::BootstrapToken', optional: true

    def stale_heartbeat?
      return true if last_heartbeat_at.nil?

      last_heartbeat_at < HEARTBEAT_STALE_AFTER.ago
    end

    # Records a heartbeat from the on-node ipn-agent. The :module_digests
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
  end
end
