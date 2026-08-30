# frozen_string_literal: true

module System
  class NodeInstance < BaseRecord
    include AASM

    # Constants
    VARIETIES = %w[cloud physical dynamic].freeze
    STATUSES = %w[pending provisioning starting running stopping stopped rebooting terminated error].freeze

    # Statuses that count as a replica the control plane still expects to
    # serve — capacity metrics (ProjectMetricsCollector's replica_count /
    # region_count) measure the fleet against this, NOT against `active`.
    #
    # Every non-terminal state is in: `pending`/`provisioning` are replicas on
    # the way up, and `starting`/`stopping`/`rebooting` are mid-lifecycle, not
    # failed — a replica rebooting is one the mission expects back in seconds,
    # and treating it as lost would make every routine reboot read as capacity
    # loss. `stopped` counts too: the mission still owns that replica, and the
    # remediation it needs is a start, not a second provision.
    #
    # That is also why this is NOT the `active` scope below, despite the cost
    # of a second definition. `active` omits `starting` and `rebooting` — and
    # those two states are exactly what the platform's OWN remediation
    # produces (FleetDecisionEngine#reboot_silent_instance issues `reboot` or
    # `start`). Sizing capacity on `active` would therefore emit capacity
    # drift for the instance currently being repaired, and propose a
    # replacement provision alongside the in-flight reboot: a self-amplifying
    # loop. It would also drift through the whole minutes-long `starting`
    # window of every fresh cloud provision.
    #
    # Only the two states that say the control plane can NOT count on the row
    # are out. `terminated` is gone. `error` is written by five paths and four
    # of them are authoritative about the instance, not merely about our view
    # of it: ProvisioningService#mark_instance_errored (the provision failed —
    # there is no VM), the two `finalize_state_from_cloud` controller paths and
    # NodeInstanceGating#execute_local_provider_action_sync! (the PROVIDER
    # itself reports error), and the `revert_termination` event below (a
    # terminate stamp whose provider call then failed — a provably unknown
    # state nothing may size against). The fifth,
    # FleetDecisionEngine#reap_presumed_dead!, is the weak one: it probes the
    # control-plane channel, so a partitioned-but-serving VM can land here.
    # It is still excluded — the honest answer to "we cannot observe this
    # replica" is never "assume it is fine", which is precisely what counting
    # it asserted. That case is not silent either way: the reap emits
    # `system.instance_presumed_dead` at :critical on its own lane.
    #
    # Deliberately spelled out rather than derived as `STATUSES - [...]`: a
    # status added later is excluded until someone decides it belongs, so the
    # failure mode of forgetting is an over-eager drift signal (visible, and
    # bounded by the target it converges on) rather than a silently inflated
    # count (invisible — the exact defect IMP-797a87dbd0bd fixed).
    LIVE_REPLICA_STATUSES = %w[pending provisioning starting running stopping stopped rebooting].freeze
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
    # Operator who placed the current ops hold. Optional: a hold is only ever
    # set through InstanceOpsHoldService, which requires a user, but historical
    # rows and released holds carry nil.
    belongs_to :ops_held_by, class_name: "User", foreign_key: :ops_hold_by_id, optional: true
    # Account is denormalized as a first-class column (mirroring sibling
    # tables like system_provider_volumes, system_acme_certificates).
    # The before_validation callback below inherits the value from the
    # parent Node so callers can omit it; a validation check keeps the
    # two in sync.
    belongs_to :account
    belongs_to :provider_region, class_name: "System::ProviderRegion", optional: true
    belongs_to :provider_instance_type, class_name: "System::ProviderInstanceType", optional: true
    # Slice 7 — optional pool membership.
    belongs_to :instance_pool,
               class_name: "System::InstancePool",
               optional: true


    # Task associations (Release 4)
    # Task association + removal policy: see System::PreservesTaskHistory.
    # Tasks are TRANSITIONED on removal, never deleted — a deleted task is
    # indistinguishable from one that never ran.
    include System::PreservesTaskHistory

    # `config` is a SHARED jsonb document with a dozen unaware writers (see
    # System::ConfigDocument). Write a key with #merge_config! / remove one with
    # #delete_config_keys! — never a read-modify-write of the whole document,
    # which silently erases whatever landed in the interval.
    include System::ConfigDocument

    # Volume associations (Release 4)
    has_many :provider_volumes, class_name: "System::ProviderVolume"

    before_validation :inherit_account_from_node
    validate :account_matches_node

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
    # provider_guest_name is the name the guest was CREATED with, captured at
    # provision time. It is deliberately not `name`: PATCH .../node_instances/:id
    # permits :name and renames only the row — nothing calls `qm set --name` — so
    # the row's name drifts from the guest's. Terminate's recycled-vmid check
    # compares against this stable value; using the mutable one would make a
    # renamed instance's GENUINE migration look like a recycled id and wrongly
    # report it gone (IMP-708079f866d9). nil on pre-existing rows, which the
    # check treats conservatively.
    store_accessor :config, :cloud_instance_id, :admin_user, :provider_guest_name

    # SSH target address for the platform→node control channel
    # (SshExecutionService + internal serializer). Preference: SDWAN overlay
    # (reachable across sites) > private LAN > public.
    #
    # F5-01: callers invoked this method since the SSH substrate was written
    # but it was never defined — every real SSH execution raised
    # NoMethodError, silently swallowed into Runtime::Result.err (all caller
    # specs stubbed the service, so nothing caught it).
    def ssh_ip_address
      vpn_ip_address.presence || private_ip_address.presence || public_ip_address.presence
    end

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

      # Terminate must be reachable from ANY non-terminal state: once the
      # provider destroys the cloud resource, the DB row must always reach
      # :terminated. Restricting `from` to running/stopped/error left
      # instances destroyed while :pending/:provisioning/:starting stranded
      # in a non-terminal status forever. See audit 2026-06-09 finding F4-02.
      event :terminate do
        transitions from: [ :pending, :provisioning, :starting, :running, :stopping, :stopped, :rebooting, :error ], to: :terminated
      end

      # Worker runtime finalizers
      event :mark_provisioning do
        transitions from: :pending, to: :provisioning
      end

      # IMP-0d7071dc03f7: :stopping is included so a failed "stop" can revert
      # to running (InstanceControlService#revert_status) and so an
      # out-of-band "running" report during a stalled stop reconciles
      # correctly — same shape as :rebooting already being here for a
      # failed reboot's revert.
      #
      # IMP-42cf03360656: :error is included so a heartbeat that resumes
      # after a transient partition (or the presumed-dead reap's running ->
      # error correction — see FleetDecisionEngine#reap_presumed_dead!) can
      # self-heal the instance back to running. Without :error here,
      # may_mark_running? was false for every errored row, so
      # StatusController#heartbeat's `mark_running! if may_mark_running?`
      # silently no-op'd and a perfectly healthy instance stayed stranded in
      # :error forever — physical instances (no CloudSync overwrite to
      # accidentally repair them) needed a manual operator "start".
      # F1 guard (IMP 019fe4c4-b373): a heartbeat can only prove a VM is
      # running — WHOSE VM it is depends entirely on the identity seed it
      # booted with. When a seed-contaminated VM heartbeats as an instance
      # whose provisioning never completed (no cloud_instance_id), the
      # self-heal below manufactured a "running" instance the provider has
      # never seen. Cloud/dynamic rows therefore need a provider identity
      # before any transition to :running; physical instances have no cloud
      # id by nature and keep the IMP-42cf03360656 stranded-row self-heal.
      event :mark_running do
        transitions from: [ :starting, :stopping, :rebooting, :provisioning, :pending, :error ], to: :running,
                    guard: :provider_identity_present?
      end

      # IMP-0d7071dc03f7: :starting is included so a failed "start" can
      # revert to stopped (InstanceControlService#revert_status) — mirrors
      # :running already being here for out-of-band stop detection while
      # a row sits in a running-adjacent transitional state.
      event :mark_stopped do
        transitions from: [ :stopping, :starting, :running ], to: :stopped
      end

      event :mark_terminated do
        transitions from: [ :terminated, :stopped, :running, :error ], to: :terminated
      end

      # Undo a terminate stamp whose provider action then FAILED. The terminate
      # event has no transitional state — it lands directly on :terminated
      # before the provider call runs — so a provider-side failure needs a way
      # back out, or the row records a destroy that never happened (an orphaned,
      # still-billable instance nothing revisits). Only
      # InstanceControlService#revert_status calls this; a row whose terminate
      # actually succeeded must stay :terminated.
      event :revert_termination do
        transitions from: :terminated, to: :error
      end

      event :mark_errored do
        transitions from: [ :pending, :provisioning, :starting, :running, :stopping, :rebooting ], to: :error
      end
    end

    # Guard for mark_running (F1): cloud/dynamic instances must carry the
    # provider-confirmed identity before any heartbeat can flip them running —
    # a row without cloud_instance_id provably never completed provisioning,
    # so the "instance" heartbeating under its identity is some OTHER machine
    # holding its seed. Physical instances have no cloud id by nature.
    def provider_identity_present?
      return true unless %w[cloud dynamic].include?(variety.to_s)

      cloud_instance_id.present?
    end

    # M4 audit trail — `prepend` so our overrides take precedence over the
    # bang methods AASM defines directly on the class. `super` inside our
    # overrides resolves to AASM's implementation, which performs the
    # actual state transition; we then write the audit row.
    prepend System::LifecycleAuditable

    # Scopes
    # === Operator ops hold ===
    #
    # A hold blocks the platform from STARTING this instance while offline work
    # is happening on its disks. See the migration for the incident that
    # motivated it: a start that arrived 30s after a stop, while the hypervisor
    # still had the guest's filesystem mounted read-write, silently truncated a
    # file to zero bytes in the guest's view.
    #
    # Expiry ALERTS, it does not release. `held?` stays true past
    # ops_hold_expires_at on purpose — a hold that lifts itself part-way through
    # maintenance is worse than no hold, because the operator believes they are
    # protected. Release is always explicit.
    scope :ops_held, -> { where.not(ops_hold_at: nil) }

    def ops_held? = ops_hold_at.present?

    def ops_hold_expired?
      ops_held? && ops_hold_expires_at.present? && ops_hold_expires_at.past?
    end

    # Human-facing single line for refusal messages and status output. The
    # "who and why" is the whole reason this is a lease rather than a flag.
    def ops_hold_summary
      return nil unless ops_held?

      who   = ops_held_by&.email.presence || ops_hold_by_id.presence || "unknown"
      since = ops_hold_at.iso8601
      base  = "held by #{who} since #{since}"
      base += " — #{ops_hold_reason}" if ops_hold_reason.present?
      base += " (lease expired #{ops_hold_expires_at.iso8601}; still held, release is explicit)" if ops_hold_expired?
      base
    end

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
    # Capacity-metric liveness — see LIVE_REPLICA_STATUSES for why this is a
    # second definition rather than a reuse of `active` (which omits the
    # transitional states).
    scope :live_replicas, -> { where(status: LIVE_REPLICA_STATUSES) }
    # Claim-by-ID fleet flow: a physical instance pre-registered by an operator,
    # still pending and not yet bound to a device, is eligible to be claimed by
    # a booting device that presents its ID (baked into /boot/identity.cfg).
    # Once claimed (claimed_at set) it drops out of this scope — single-bind,
    # no re-claim, so a leaked ID can't hijack an already-provisioned device.
    scope :claimable, -> { physical.where(status: "pending", claimed_at: nil) }

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

    # Server-side SDWAN reachability gate for pool promotion (native-CI pool
    # reliability fix). A pool builder enrolled onto an SDWAN overlay at
    # provision time (ProvisioningService#auto_enroll_sdwan_peer! creates an
    # Sdwan::Peer whenever the pool declares metadata["sdwan_network_id"]) is
    # NOT usable the instant it first heartbeats: its WireGuard tunnel to the
    # overlay hub may not have handshaked yet, so overlay-only names — e.g. the
    # CI git registry git.powernode.org, which resolves to an overlay address —
    # are unreachable and a dispatched `git clone` times out. Gating readiness
    # on the tunnel being live is what keeps a still-isolating builder from
    # being acquired and handed a build it can't fetch.
    #
    # The agent already reports per-peer handshake state to
    # NodeApi::SdwanController#report, which persists Sdwan::Peer#last_handshake_at
    # — so the platform reliably knows, with NO agent change, whether the overlay
    # tunnel is live. Read last_handshake_at directly (against the model's healthy
    # window) rather than the recompute-lagged status column, mirroring
    # Fleet::Sensors::SdwanReachabilitySensor.
    #
    #   - No Sdwan::Peer rows → true. The instance is not overlay-attached
    #     (non-SDWAN pool); overlay reachability is not a precondition, so this
    #     preserves the pre-existing "ready on first heartbeat" behavior.
    #   - Has peer rows       → true only once at least one peer has a fresh
    #     WireGuard handshake (last_handshake_at within Sdwan::Peer's healthy
    #     window) — i.e. the overlay is actually up from this node.
    #
    # Guarded by defined?(::Sdwan::Peer): if the SDWAN layer is somehow absent,
    # degrade to "ready" (no worse than the pre-gate behavior) rather than
    # stranding pool promotion.
    def sdwan_overlay_ready?
      return true unless defined?(::Sdwan::Peer)

      peers = ::Sdwan::Peer.where(node_instance_id: id)
      return true unless peers.exists?

      peers.where("last_handshake_at >= ?", ::Sdwan::Peer::HEALTHY_HANDSHAKE_WINDOW.ago).exists?
    end

    # Module names whose actual composition on the node — reported in the
    # agent heartbeat's running_module_digests — is a precondition for a pool
    # member to become acquirable. A native-CI builder leased before its
    # module-forge union is mounted execs a module-forge-provided build script
    # that isn't on the union yet, and the agent dead-ends the ci.module_build
    # task at "unknown_command" (agent tasks/loop.go). Keeping the builder
    # "warming" until the module is reported running closes that race — the
    # module-composition analog of #sdwan_overlay_ready?. Kept in step with the
    # module-forge module the native build path gates on
    # (Api::V1::System::NodeApi::ConfigController::MODULE_FORGE_MODULE_NAME).
    POOL_READINESS_REQUIRED_MODULE_NAMES = %w[module-forge].freeze

    # Server-side module-composition gate for pool promotion (native-CI pool
    # reliability fix — improvement 019f6ecc-7e0e). running_module_digests is
    # the agent heartbeat's map of node_module_id → mounted oci_digest, so the
    # platform knows exactly which of a node's assigned modules are actually
    # composed. A builder whose node is assigned a build-critical module (see
    # POOL_READINESS_REQUIRED_MODULE_NAMES) is only ready once that module
    # appears there.
    #
    #   - Node assigned none of the required modules → true. Every non-builder
    #     pool is unaffected; overlay + heartbeat liveness alone decide, exactly
    #     as before this gate (mirrors how #sdwan_overlay_ready? degrades for a
    #     non-SDWAN pool).
    #   - Node assigned one/more → true only once EACH is reported composed in
    #     running_module_digests (keyed by node_module_id, matching
    #     Fleet::PromotionCriteria's own digest lookups).
    def required_modules_composed?
      return true unless node

      required = node.node_modules.where(name: POOL_READINESS_REQUIRED_MODULE_NAMES)
      required_ids = required.pluck(:id)
      return true if required_ids.empty?

      running = running_module_digests || {}
      required_ids.all? { |mid| running.key?(mid.to_s) }
    end

    # Idempotent transition: warming → ready (called from provisioning
    # success callback / heartbeat success). Returns true if the
    # transition succeeded, false if state didn't allow it (e.g. already
    # ready, claimed, draining, etc.), if the instance's SDWAN overlay
    # tunnel is not yet live (#sdwan_overlay_ready?) — a builder acquired
    # before its overlay handshake completes cannot reach overlay-only build
    # inputs (git.powernode.org) — or if a build-critical module the node is
    # assigned is not yet composed (#required_modules_composed?), so it must
    # stay "warming" until it can.
    def mark_pool_ready!
      return false unless in_pool?
      return false unless pool_state == "warming"
      return false unless sdwan_overlay_ready?
      return false unless required_modules_composed?
      update!(pool_state: "ready")
      true
    end

    # Promotes a "warming" pool member to "ready" and emits a FleetEvent so
    # the promotion is fleet-observable — the counterpart to mark_pool_ready!
    # for callers that also want observability (StatusController#heartbeat is
    # the only caller today: a heartbeat is the platform's sole evidence that
    # a pool-provisioned instance actually enrolled and is alive, so it's the
    # natural trigger to flip warming → ready). No-op (returns false, no
    # event) for a non-pool instance or one not currently "warming" —
    # mark_pool_ready! already provides that guard, so this is safe to call
    # unconditionally on every heartbeat, not just the first.
    #
    # Best-effort event emission: a FleetEvent persistence hiccup must never
    # raise back into the heartbeat response the agent is waiting on.
    def promote_pool_ready!
      return false unless mark_pool_ready!

      ::System::Fleet::EventBroadcaster.emit!(
        account: account,
        kind: "system.pool.member_ready",
        severity: :low,
        payload: { pool_id: instance_pool_id, instance_id: id },
        source: "node_instance#promote_pool_ready!",
        node_instance_id: id
      )
      true
    rescue StandardError => e
      Rails.logger.warn("[NodeInstance] pool promotion event emit failed for #{id}: #{e.class}: #{e.message}")
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

    # IMP-57e9a90598ee — the production writer suggest_network_profile never
    # had. Called from the heartbeat endpoint immediately after
    # record_heartbeat! persisted the agent-observed architecture — the last
    # fact the suggester needs — and BEFORE mark_running!, so it fires only
    # on the heartbeat that brings a pre-running instance up.
    #
    # first_contact: the caller must declare whether this is the instance's
    # FIRST heartbeat ever (last_heartbeat_at was nil before this request
    # stamped it). The caller captures that, because by the time this runs
    # record_heartbeat! has already written the column. Without this guard,
    # "first heartbeat" was really "first stamp-less non-running heartbeat":
    # every pre-existing instance carries no stamp, so the whole legacy fleet
    # would auto-classify — and eligible hosts silently promote to
    # heavyweight — on its next pass through a non-running state (a reboot, a
    # presumed-dead self-heal). That is the fleet-wide profile wave this
    # method's guards exist to prevent, merely amortised over reboots.
    #
    # Guards, each load-bearing:
    #   - only the instance's first contact ever (first_contact): legacy
    #     hosts NEVER auto-classify; operators promote them explicitly via
    #     system_update_instance.
    #   - only a pre-running instance (may_mark_running?): an established
    #     fleet must never profile-flip on deploy.
    #   - only once (the network_profile_source stamp): a classification is
    #     a birth event, not a reconcile loop.
    #   - never over an operator declaration ("operator" source wins).
    #   - never a demotion: the suggester's "lightweight" is its safe
    #     default, not evidence a heavyweight host lost headroom.
    #
    # (architecture needs no guard: the column is NOT NULL + CHECKed, so an
    # instance without one is unrepresentable; the unknown-fact path is
    # available_memory_mb returning nil, which the suggester already treats
    # as "cannot prove headroom" → lightweight.)
    def classify_network_profile!(first_contact:)
      return false unless first_contact
      return false unless may_mark_running?
      return false if config&.dig("network_profile_source").present?

      suggestion = suggest_network_profile
      promote = suggestion == "heavyweight" && network_profile == "lightweight"

      # Column and config document written SEPARATELY — see
      # System::ConfigDocument. This runs INSIDE the heartbeat request cycle,
      # alongside the four telemetry writers, so folding the jsonb into the
      # same `update!` would have this path erase its own siblings' documents.
      transaction do
        update!(network_profile: promote ? "heavyweight" : network_profile)
        merge_config!("network_profile_source" => "suggested_first_heartbeat")
      end

      if promote
        ::System::Fleet::EventBroadcaster.emit!(
          account: account,
          kind: "system.instance.network_profile_promoted",
          severity: :low,
          payload: {
            instance_id: id,
            suggested: suggestion,
            architecture: architecture,
            memory_mb: available_memory_mb
          },
          source: "node_instance#classify_network_profile!",
          node_instance_id: id
        )
      end
      promote
    rescue StandardError => e
      Rails.logger.warn("[NodeInstance] network profile classification failed for #{id}: #{e.class}: #{e.message}")
      false
    end

    # === Runtime telemetry (Golden Eclipse M0.M) ===
    # Used by powernode-agent heartbeat path (M0.O / M0.P / M2). Maintains
    # last_heartbeat_at, agent_version, boot_id, and the running_module_digests
    # snapshot so FleetAutonomyService (M7) can detect drift.

    HEARTBEAT_STALE_AFTER = 3.minutes

    # Cap for the node-supplied identifier strings ingested by
    # #record_heartbeat! below (agent_version, boot_id, booted_image_git_sha).
    # The heartbeat is written by an mTLS-authenticated node principal, but
    # the value itself is arbitrary node input with no DB-level bound (plain
    # `t.string` columns, unbounded on Postgres) — and it is later echoed
    # verbatim to an MCP read surface (system_get_instance /
    # system_list_instances), so an oversized value is a context-window /
    # storage cost concern (IMP-dab7cb6a117a), not a validation concern:
    # truncate here, never reject, so a malformed field can't fail an
    # otherwise-good heartbeat.
    #
    # The bound itself lives in System::IdentifierCaps, stated once. The three
    # state writers bound strings inside the `config` jsonb sub-documents they
    # own via raw update_all SQL; this bounds real model columns assigned
    # through the ordinary AR attribute path. Different helpers, same number —
    # and a second literal kept in step by a comment is the drift this fixes.
    MAX_IDENTIFIER_CHARS = ::System::IdentifierCaps::MAX_IDENTIFIER_CHARS

    has_many :node_certificates, class_name: "System::NodeCertificate", dependent: :destroy
    belongs_to :enrollment_token, class_name: "System::BootstrapToken", optional: true

    def stale_heartbeat?
      return true if last_heartbeat_at.nil?

      last_heartbeat_at < HEARTBEAT_STALE_AFTER.ago
    end

    # Records a heartbeat from the on-node powernode-agent. The :module_digests
    # parameter is a hash of { module_id => oci_digest } captured by the agent.
    # :booted_image_git_sha is the git_sha baked into the disk image the node
    # actually booted from (read from the UKI kernel cmdline); absent on nodes
    # running older agents or images built before campaign 019f505f.
    #
    # agent_version / boot_id / booted_image_git_sha are truncated to
    # MAX_IDENTIFIER_CHARS before persisting — see the constant's comment.
    def record_heartbeat!(agent_version:, boot_id:, module_digests: {}, architecture: nil, booted_image_git_sha: nil)
      boot_id = cap_identifier_length(boot_id)
      agent_version = cap_identifier_length(agent_version)
      booted_image_git_sha = cap_identifier_length(booted_image_git_sha)

      attrs = {
        last_heartbeat_at: Time.current,
        agent_version: agent_version,
        boot_id: boot_id,
        running_module_digests: (module_digests || {}).to_h
      }
      attrs[:architecture] = architecture if architecture.present?
      # Boot-image sha (campaign 019f505f): a reported sha always wins. A heartbeat
      # that reports NO sha on a *new* boot (boot_id changed) means the node booted
      # an image that can't self-identify (a pre-campaign image, or a rollback) —
      # clear the stale value so it reads "unknown", never false drift against the
      # last image. A no-sha heartbeat on the *same* boot (agent restart, or an old
      # agent that never reports it) leaves the existing value untouched.
      if booted_image_git_sha.present?
        attrs[:booted_image_git_sha] = booted_image_git_sha
      elsif boot_id.present? && self.boot_id.present? && self.boot_id != boot_id
        attrs[:booted_image_git_sha] = nil
      end
      update!(attrs)
    end

    # The git_sha of the disk image currently promoted for this instance's
    # platform (Node → NodeTemplate → NodePlatform.disk_image_git_sha, set by
    # the DiskImage::PromotePublication executor). Nil when the platform has no
    # promoted image yet or the Node/Template links aren't populated.
    def promoted_image_git_sha
      node&.node_platform&.disk_image_git_sha
    end

    # True when the node has reported a booted image sha that differs from the
    # platform's promoted image sha — i.e. it is running a stale boot image and
    # a smooth upgrade would converge it. Read-only: never mutates. Returns
    # false unless BOTH shas are known (an unknown side is "no evidence of
    # drift", not drift).
    def boot_image_drifted?
      booted = booted_image_git_sha
      promoted = promoted_image_git_sha
      booted.present? && promoted.present? && booted != promoted
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

    # === GPU / accelerator capability (audit P6) ===
    #
    # Resolved like #available_memory_mb: prefer the bound
    # provider_instance_type (cloud / templated physical declares its SKU),
    # then fall back to a `config["gpu"]` hint
    # (`{ "count" => 1, "type" => "H100", "memory_mb" => 81920 }`).
    # Public — read by GPU discovery (system_find_node_with_gpu) + scheduling.
    #
    # The hint's producer is the on-node agent (IMP-657e05418572): it detects
    # the inventory once per boot via nvidia-smi, falling back to lspci, and
    # ships it inside the node_capabilities heartbeat block, which
    # #record_capabilities! maps into config through
    # #apply_agent_hardware_hints!. Two consequences worth knowing:
    #   - "count" may be absent (agent could run NEITHER detector — unknown)
    #     or 0 (a detector ran and found none). Those are different facts and
    #     the ingest keeps them apart; #gpu_count collapses both to 0 because
    #     an unknown accelerator is not a schedulable one.
    #   - "memory_mb" is absent on the lspci fallback path, which cannot see
    #     VRAM. A GPU node can therefore report a count and type with no VRAM.
    # An operator-set hint is never overwritten by detection.
    def gpu_count
      type_count = provider_instance_type&.gpu_count.to_i
      return type_count if type_count.positive?

      Integer(config&.dig("gpu", "count") || 0)
    rescue ArgumentError, TypeError
      0
    end

    def gpu_type
      provider_instance_type&.gpu_type.presence || config&.dig("gpu", "type").presence
    end

    def gpu_memory_mb
      type_mb = provider_instance_type&.gpu_memory_mb
      return type_mb if type_mb

      raw = config&.dig("gpu", "memory_mb")
      raw.nil? ? nil : Integer(raw)
    rescue ArgumentError, TypeError
      nil
    end

    def gpu?
      gpu_count.positive?
    end

    # === Boot composition (docs/PIVOT_ROOT_CLOUD_VM_DESIGN.md) ===

    # boot_mode values whose module union is composed PRE-pivot/switch_root
    # — the node's root filesystem *is* the erofs+overlay module
    # composition. That union is boot-time-fixed: a live module refresh
    # updates `running_module_digests` but the mounted union is never
    # remounted without a reboot (campaign 019f6084 §2.4.3 — the
    # template-closure drift sensor's remediation split on this predicate).
    # "cloud_init" boots a full guest OS and composes the union under a
    # chrootable RootDirectory, which the on-node reconcile loop CAN
    # remount live. An unset boot_mode is not a third value — it means no
    # one resolved it; see #pivot_boot? for why that is not benign.
    PIVOT_BOOT_MODES = %w[direct_kernel uefi_disk].freeze

    # True when this instance was provisioned with a pivot boot_mode.
    #
    # The instance's OWN config["boot_mode"] is authoritative: ProvisioningService
    # resolves the effective boot mode at spawn (an explicit options[:boot_mode]
    # first, else the template's config["boot_mode"]) and stamps the value it
    # hands the provider onto this row. Re-deriving it from the template — as
    # this did before IMP-831a81e02d25 — gets the override case backwards: an
    # instance spawned direct_kernel by a spawn option on a template declaring
    # no boot_mode read back false.
    #
    # The template lookup is the FALLBACK, and it is not vestigial: rows
    # provisioned before the stamp existed carry no key, and so do rows that
    # never went through ProvisioningService at all (the bare-metal claim seed,
    # a direct POST to NodeInstancesController#create). All of those keep
    # exactly the answer they had. The stamp is also not durable against a
    # caller-supplied whole `config` document — NodeInstancesController#update
    # permits `config: {}` and assigns it wholesale, so a PUT omitting the key
    # drops the stamp back to the fallback. That is the pre-existing
    # shared-document hazard System::ConfigDocument describes, not something
    # this predicate can fix.
    #
    # Unset still resolves to false. That is NOT the "safe" default this comment
    # used to call it — it is UNRESOLVED, and its error direction is the unsafe
    # one. When neither the options nor the template declare a boot mode, each
    # adapter applies its own (cloud_init for ProxmoxProvider, direct_kernel for
    # LocalQemuProvider) and does not report which back to the spawn path — its
    # create_instance response carries no boot_mode key at all — so there is
    # nothing to stamp. On LocalQemu that leaves a FALSE NEGATIVE, and the error
    # direction is the unsafe one: Fleet::DecisionEngine#apply_template_closure_drift
    # takes the NON-pivot arm, which dispatches a `sync_modules` reconcile task
    # that a boot-time-fixed union cannot act on. The PIVOT arm declares
    # `convergence_deferred` immediately (IMP-848c7e953e2d); the non-pivot arm
    # reaches the same declaration only via reboot_pending_escalation, i.e.
    # AFTER the agent has failed one reconcile — so a false negative DELAYS the
    # declaration by a round trip rather than losing it, and that arm can also
    # legitimately return applied: false for its own reasons (a disruption
    # budget, a missing target). The consequences live in DecisionEngine and
    # RemediationValidator; this note only records the error direction, so the
    # unset default is not mistaken for a decision. Making the adapter defaults
    # observable is out of scope here.
    def pivot_boot?
      own_config = config
      boot_mode = own_config.is_a?(Hash) ? (own_config["boot_mode"] || own_config[:boot_mode]) : nil

      if boot_mode.blank?
        tmpl_config = node&.node_template&.config
        boot_mode = tmpl_config.is_a?(Hash) ? (tmpl_config["boot_mode"] || tmpl_config[:boot_mode]) : nil
      end

      PIVOT_BOOT_MODES.include?(boot_mode.to_s)
    end

    # Best-effort memory lookup. PUBLIC, like the gpu_* capacity readers above.
    # Read by #suggest_network_profile AND, since IMP-938ee27f4921, by
    # System::ProjectMetricsCollector, which turns the heartbeat's
    # memory_free_kb into memory_pct.
    #
    # Reads from provider_instance_type when the instance has one (cloud
    # variety / templated physical), then falls back to a `config["memory_mb"]`
    # hint — operator-asserted, or written by the on-node agent from
    # /proc/meminfo MemTotal (IMP-657e05418572; see
    # #apply_agent_hardware_hints!). Returns nil when nothing is known.
    #
    # MemTotal is INSTALLED capacity minus what the kernel reserved before
    # reporting it, so an agent-written value reads a little under nameplate
    # (a "4GB" board reports ~3.8GB) — that rounding biases toward the safe
    # lightweight profile.
    #
    # But do not read that as "this change cannot promote anything". BEFORE
    # the agent produced this hint, a bare-metal instance with no bound SKU
    # had NO memory fact at all, so #suggest_network_profile always took its
    # "cannot prove headroom" branch. Producing a value at all is what
    # changes the outcome: an amd64 host with >= HEAVYWEIGHT_MIN_MEMORY_MB
    # now classifies as heavyweight on its FIRST heartbeat, and a Pi 5 does
    # so at any RAM. classify_network_profile!'s guards still confine that to
    # first contact and never demote, so there is no wave over the existing
    # fleet — but every newly-enrolled bare-metal node is affected, and
    # heavyweight is what gates the OVS+OVN lane
    # (Sdwan::Ovn::DeploymentReconciler, HostBridgeAllocator).
    #
    # THE NIL CONTRACT IS UNCHANGED and both callers honour it: nil means
    # "unknown", never zero. The suggester treats it as "assume too small" and
    # defaults to the safe lightweight profile; the collector EXCLUDES the
    # instance from the mean rather than contributing a fabricated reading.
    def available_memory_mb
      type_mb = provider_instance_type&.memory_mb
      return type_mb if type_mb

      raw = config && config["memory_mb"]
      return nil if raw.nil?
      Integer(raw)
    rescue ArgumentError, TypeError
      nil
    end

    private

    # Truncates (never rejects) a node-supplied identifier string to
    # MAX_IDENTIFIER_CHARS before it is persisted — see that constant's
    # comment for why this bounds rather than validates. Non-string / blank
    # input passes through unchanged so the existing `.present?` branches in
    # #record_heartbeat! keep their nil-vs-blank-vs-absent semantics.
    def cap_identifier_length(value)
      return value unless value.is_a?(String)
      return value if value.length <= MAX_IDENTIFIER_CHARS

      value[0, MAX_IDENTIFIER_CHARS]
    end

    # Best-effort hardware-model lookup, normalised to a lowercase
    # snake_case token. Reads from `config["hardware_model"]` —
    # operator-asserted at row creation, or written by the on-node agent
    # (IMP-657e05418572) from /sys/class/dmi/id/product_name, falling back to
    # /proc/device-tree/model on boards with no DMI (Raspberry Pi and other
    # device-tree SBCs). The agent reports the firmware string VERBATIM, and
    # .canonical_hardware_model — which runs ON THE INGEST PATH ONLY, not
    # here — maps the Pi variants onto the tokens HEAVYWEIGHT_PI_MODELS /
    # PI4_HARDWARE_MODELS actually match, since those are exact-equality
    # lists and a raw "Raspberry Pi 5 Model B Rev 1.0" normalises to
    # something none of them contain. An operator who hand-sets that same
    # raw string therefore still gets no match; they must write the token.
    # Returns nil when nothing is known — the suggester then
    # falls through to lightweight via the safe default. The
    # `discovered_dmi_uuid` column is intentionally skipped here (DMI UUID is
    # opaque and not a model discriminator).
    def hardware_model_hint
      raw = config && config["hardware_model"]
      return nil if raw.nil? || raw.to_s.strip.empty?
      raw.to_s.downcase.strip.gsub(/[\s-]+/, "_")
    end

    # Inherit account_id from the parent Node when unset. Callers can
    # create NodeInstance with just `node:` and skip `account:`; this
    # callback fills it in before validation runs.
    def inherit_account_from_node
      self.account_id ||= node&.account_id
    end

    # Defense in depth: refuse to save a row whose denormalized
    # account_id has drifted from the parent Node's account_id. Nodes
    # don't migrate accounts in practice, so this is a "should never
    # happen" guard, not a hot path.
    def account_matches_node
      return if node.nil? || account_id.nil?
      return if account_id == node.account_id
      errors.add(:account_id, "must match node.account_id (got #{account_id.inspect}; node has #{node.account_id.inspect})")
    end

    public

    # === Capability helpers (agent-reported, refreshed each heartbeat) ===
    # The agent advertises kernel features (erofs, overlayfs, fs-verity)
    # on every heartbeat. The platform records them for fleet
    # introspection ("which nodes can mount erofs?") and as a sanity
    # gate before assigning modules. `public` keyword restores
    # visibility since these helpers landed after the `private` block
    # above; the heartbeat controller calls `record_capabilities!`
    # directly so it MUST be public.

    # Reads a capability value. Stringifies the key for forgiveness;
    # returns nil when the capabilities hash is empty or the key is
    # missing.
    def capability(key)
      return nil if capabilities.blank?
      capabilities[key.to_s]
    end

    # True iff the agent reports erofs availability. An empty caps
    # hash (no heartbeat yet) is treated as "assume available" —
    # erofs has been in mainline since 5.4 (2019), enabled in every
    # distro we target. This avoids deadlocking the very first
    # reconcile cycle which happens BEFORE the agent's first heartbeat
    # lands.
    def supports_erofs?
      return true if capabilities.blank?
      capability("erofs_available") == true
    end

    # Replace the capabilities hash with a fresh agent report. Merges
    # the detected_at timestamp so we can detect stale caps in
    # heartbeat-cadence reviews.
    #
    # Also derives the hardware config hints from the SAME report
    # (IMP-657e05418572) — the agent carries GPU/RAM/chassis inventory
    # inside this block rather than on a channel of its own, so this is
    # the one ingest point for both.
    def record_capabilities!(caps)
      return if caps.blank?
      normalized = caps.stringify_keys
      update_columns(capabilities: normalized.merge("detected_at" => Time.current.iso8601))
      # Wrapped like the heartbeat controller's other derived writers
      # (classify_network_profile!, the OVN reconciler): a bug in a
      # convenience mapping must never bounce a node's telemetry, which is
      # the signal an operator needs most when something is wrong.
      begin
        apply_agent_hardware_hints!(normalized)
      rescue StandardError => e
        Rails.logger.warn("[NodeInstance] hardware hint ingest failed for #{id}: #{e.class}: #{e.message}")
      end
    end

    # === Agent hardware inventory → config hints (IMP-657e05418572) ===
    #
    # #gpu_count / #gpu_type / #gpu_memory_mb / #available_memory_mb /
    # #hardware_model_hint all document a fallback to a `config` hint the
    # on-node agent reports. This is the producer that makes that true.
    # Nothing here changes those readers' signatures or precedence — a
    # bound provider_instance_type still wins.

    # Provenance stamp: a hash of the hint VALUES the agent last wrote,
    # e.g. {"memory_mb" => 257000, "hardware_model" => "PowerEdge R740"}.
    #
    # Values, not a list of key names, and that distinction is the whole
    # guard. A key-name list says "the agent owns this key" forever, and
    # the stamp round-trips through the ordinary operator edit path —
    # NodeInstancesController#update permits `config: {}` wholesale and
    # the serializer hands the operator the entire config, stamp included
    # — so an operator correcting a hint would hand the ownership claim
    # right back and get silently overwritten on the next heartbeat.
    #
    # Comparing values instead makes the guard self-invalidating under
    # ANY writer, including ones that have never heard of this stamp: the
    # agent may refresh a hint only while the stored value is still
    # exactly what it last wrote. The moment anything else changes it,
    # the agent leaves it alone. (An operator who edits the hint AND
    # forges the matching stamp entry re-arms it; that is a deliberate
    # act, not an accident.)
    AGENT_HARDWARE_HINT_SOURCE_KEY = "agent_hardware_hints"

    # Model strings the network-profile suggester recognises, keyed by the
    # firmware string that identifies them. The agent reports the model
    # VERBATIM ("Raspberry Pi 5 Model B Rev 1.0"); the platform's
    # vocabulary lives here, next to HEAVYWEIGHT_PI_MODELS which defines
    # it, so the agent needs no knowledge of it. Anything unmatched passes
    # through unchanged and #hardware_model_hint normalises it as before.
    CANONICAL_HARDWARE_MODELS = {
      /\braspberry\s*pi\s*5\b/i => "raspberry_pi_5",
      /\braspberry\s*pi\s*4\b/i => "raspberry_pi_4"
    }.freeze

    # Pure mapping: agent capability report → config hints. Returns ONLY
    # the keys detection actually produced. An absent key means the agent
    # could not measure that fact, which is a different fact from a
    # measured zero — so an absent gpu_count yields no "gpu" hint at all,
    # while gpu_count=0 yields {"count" => 0}.
    def self.hardware_hints_from_capabilities(caps)
      return {} if caps.blank?
      caps = caps.stringify_keys
      hints = {}

      gpu = gpu_hint_from_capabilities(caps)
      hints["gpu"] = gpu if gpu

      mb = integer_or_nil(caps["memory_total_mb"])
      hints["memory_mb"] = mb if mb

      model = caps["hardware_model"]
      if model.is_a?(String) && model.strip.present?
        hints["hardware_model"] = canonical_hardware_model(model.strip)
      end

      hints
    end

    def self.gpu_hint_from_capabilities(caps)
      count = integer_or_nil(caps["gpu_count"])
      return nil if count.nil?

      gpu = { "count" => count }
      type = caps["gpu_type"]
      gpu["type"] = type.strip if type.is_a?(String) && type.strip.present?
      mem = integer_or_nil(caps["gpu_memory_mb"])
      gpu["memory_mb"] = mem if mem
      gpu
    end
    private_class_method :gpu_hint_from_capabilities

    # Strict: a non-numeric value is treated as NOT MEASURED rather than
    # coerced to 0, which is the reading the readers must never invent.
    def self.integer_or_nil(raw)
      return nil if raw.nil?
      return raw if raw.is_a?(Integer)
      return nil unless raw.is_a?(Numeric) || (raw.is_a?(String) && raw.match?(/\A-?\d+\z/))
      Integer(raw)
    rescue ArgumentError, TypeError
      nil
    end
    private_class_method :integer_or_nil

    def self.canonical_hardware_model(raw)
      CANONICAL_HARDWARE_MODELS.each { |pattern, token| return token if raw.match?(pattern) }
      raw
    end
    private_class_method :canonical_hardware_model

    # Merge the detected hints into config WITHOUT ever clobbering a value
    # the agent did not itself write.
    #
    # Two rules, both load-bearing:
    #   1. only keys detection produced are considered — an unmeasured
    #      fact can never blank an existing value, so it does not matter
    #      whether live rows already carry hand-set hints;
    #   2. a key already present in config is written only when its stored
    #      value is still byte-identical to what the agent last wrote (see
    #      AGENT_HARDWARE_HINT_SOURCE_KEY). Any other writer's value wins
    #      and keeps winning.
    #
    # Written with `touch: false` (like record_capabilities! above) — this runs
    # on every heartbeat and must not fire callbacks or touch updated_at. The
    # no-change early return keeps the steady state write-free.
    def apply_agent_hardware_hints!(caps)
      hints = self.class.hardware_hints_from_capabilities(caps)
      return if hints.empty?

      cfg  = config || {}
      last = cfg[AGENT_HARDWARE_HINT_SOURCE_KEY]
      last = {} unless last.is_a?(Hash)

      writable = hints.select do |key, _|
        !cfg.key?(key) || cfg[key].nil? || (last.key?(key) && cfg[key] == last[key])
      end
      return if writable.empty?

      document = writable.merge(AGENT_HARDWARE_HINT_SOURCE_KEY => last.merge(writable))
      # The no-change early return is load-bearing: in steady state the agent
      # re-reports identical hints on every heartbeat, and `writable` is
      # non-empty for them (they match their recorded source). Comparing the
      # SUBSET this would write, rather than a rebuilt whole document, keeps
      # that check exact now that only the subset is written.
      return if document.all? { |key, value| cfg.key?(key) && cfg[key] == value }

      # Only the hint keys plus their provenance key — see
      # System::ConfigDocument. Another heartbeat-cycle path, and the one most
      # likely to race the telemetry writers: same request, same column.
      # `touch: false` preserves the previous #update_columns semantics.
      merge_config!(document, touch: false)
    end

    # === Cascade-destroy helpers ===
    # Tables with FK references to NodeInstance, classified by how the
    # destroy controller should handle them when force=true. See
    # NodeInstancesController#destroy for the operator workflow.
    #
    # The optional? metadata mirrors the belongs_to :node_instance,
    # optional: true vs (default required) declarations on the child
    # side. Optional FKs get NULLed; required FKs get destroyed.
    # Polymorphic + already-dependent-destroy declarations on the
    # NodeInstance side (tasks, node_certificates)
    # are omitted — Rails handles those automatically on .destroy.
    CASCADE_DEPENDENTS = [
      # Required FK — must be destroyed before the parent
      { klass: "System::NodeInstancePeer",     fk: :node_instance_id, optional: false },
      { klass: "System::StorageMigration",     fk: :node_instance_id, optional: false },
      { klass: "System::StorageAssignment",    fk: :node_instance_id, optional: false },
      { klass: "System::StorageCredential",    fk: :node_instance_id, optional: false },
      { klass: "Sdwan::HostBridge",            fk: :node_instance_id, optional: false },
      { klass: "Sdwan::HostVrfAssignment",     fk: :node_instance_id, optional: false },
      { klass: "Sdwan::Peer",                  fk: :node_instance_id, optional: false },
      # Optional FK — nullify (audit / lifecycle history retained)
      { klass: "System::BootstrapToken",       fk: :node_instance_id, optional: true  },
      { klass: "System::MountEncryptionKey",   fk: :node_instance_id, optional: true  },
      { klass: "System::NodeModule",           fk: :node_instance_id, optional: true  },
      { klass: "System::ProviderVolume",       fk: :node_instance_id, optional: true  }
    ].freeze

    # Returns the list of dependent rows currently referencing this
    # instance, grouped by table name. Used by the destroy controller
    # to give operators an actionable error before they have to dig
    # through a PG FK violation. Returns an empty hash if nothing
    # references the instance.
    def blocking_dependents
      result = {}
      CASCADE_DEPENDENTS.each do |entry|
        klass = entry[:klass].safe_constantize
        next unless klass
        count = klass.where(entry[:fk] => id).count
        result[entry[:klass]] = count if count.positive?
      end
      result
    end

    # Operator-driven dependent cascade: nullifies optional FKs +
    # destroys required-FK dependents in dependency-safe order. Called
    # by NodeInstancesController#destroy when ?force=true is set. Wrap
    # the actual instance .destroy in the SAME transaction so a
    # downstream failure rolls everything back. Returns a summary hash
    # the controller surfaces in the response.
    def cascade_destroy_dependents!
      summary = { nullified: {}, destroyed: {} }
      ActiveRecord::Base.transaction do
        CASCADE_DEPENDENTS.each do |entry|
          klass = entry[:klass].safe_constantize
          next unless klass
          scope = klass.where(entry[:fk] => id)
          count = scope.count
          next if count.zero?
          if entry[:optional]
            scope.update_all(entry[:fk] => nil)
            summary[:nullified][entry[:klass]] = count
          else
            scope.destroy_all
            summary[:destroyed][entry[:klass]] = count
          end
        end
      end
      summary
    end
  end
end
