# frozen_string_literal: true

module System
  class Task < BaseRecord
    include System::Base
    include AASM

    # === Constants ===
    STATUSES = %w[pending scheduled running complete failed aborted cancelled].freeze
    # Every command the platform can actually execute, and now a VALIDATION
    # rather than documentation.
    #
    # It is exactly ExecutionDispatcher::COMMAND_REGISTRY.keys (server-dispatched)
    # UNION ExecutionDispatcher::AGENT_DELEGATED_COMMANDS (node-executed). That
    # equality is asserted by spec rather than derived in code — deriving it here
    # would make a model load a service at class-body evaluation time, and the
    # spec catches drift just as well without the load-order coupling.
    #
    # It used to be neither. It carried volumes, snapshots, networks,
    # backup/restore and `custom` — none of which had a dispatcher or a producer
    # — while OMITTING every storage.* command and ci.package_build, which are
    # real agent-delegated verbs in daily use. So it simultaneously advertised
    # work the platform cannot do and failed to list work it does. Nothing
    # noticed, because nothing consulted it.
    #
    # VALIDATED ON CHANGE, not on every save — the same guard shape, and for the
    # same reason, as operable_type below. `command` has been effectively free
    # text for the table's lifetime, so an unconditional inclusion check would
    # make any pre-existing row carrying an unlisted command unsaveable and brick
    # its progress ticks, fail! and every other status transition. Guarding on
    # the change keeps the security property whole: every write that SETS or
    # CHANGES the command is checked (on create the attribute goes nil -> value,
    # which reads as changed), and a legacy row can never be re-pointed at an
    # unlisted command.
    #
    # Verified safe before the guard was added: 476 System::Task rows have ever
    # existed on the live control plane, across six distinct commands, every one
    # of them in this list.
    COMMANDS = %w[
      start stop restart terminate reboot
      sync_modules apply_config
      ssh_command
      upgrade_boot_image
      a2a_call
      storage.mount storage.unmount storage.exports.apply storage.smb_user.apply
      storage.gateway.provision storage.gateway.deprovision storage.chown
      ci.module_build
      ci.package_build
      probe.module_smoke
    ].freeze

    # Records that may legitimately carry a task.
    #
    # operable_type is free text on an open polymorphic belongs_to, and
    # `optional: true` means an unresolvable pair persists silently, so without
    # this a caller naming any model at all (Account, User, Ai::Agent) gets it
    # stored verbatim.
    #
    # The enumeration is the UNION of two sources, and neither alone is
    # complete: the models declaring the inverse `has_many :tasks, as: :operable`,
    # plus the types the runtime dispatchers historically accepted —
    # the retired System::Runtime::SyncCloudState handled a ProviderRegion,
    # which declares no inverse at all, and that is why the type is listed here
    # with no corresponding association. Adding a type here without a dispatch
    # arm buys nothing; adding a dispatch arm without listing it here fails
    # closed at validation.
    OPERABLE_TYPES = %w[
      System::Node
      System::NodeInstance
      System::Provider
      System::ProviderNetwork
      System::ProviderRegion
      System::ProviderVolume
      System::ProviderVolumeSnapshot
    ].freeze

    # Raised instead of a bare CrossAccountError when the TYPE is refused
    # rather than the owner. It subclasses so existing rescues and log greps
    # keep working, while a genuine cross-tenant signal stays undiluted.
    BadOperableType = Class.new(::Ai::DeferredOperation::CrossAccountError)

    # === Associations ===
    belongs_to :account
    belongs_to :operable, polymorphic: true, optional: true
    belongs_to :initiated_by, class_name: "User", optional: true

    # === Validations ===
    validates :command, presence: true
    # Guarded on the CHANGE, not on every save. operable_type has been free text
    # for the table's lifetime and ~15 non-gated producers wrote it unchecked, so
    # validating unconditionally would make any pre-existing row carrying an
    # unlisted type unsaveable — bricking progress ticks, `fail!`, and every
    # other status transition on tasks a worker is already mid-flight on. The
    # security property is unchanged: every write that SETS or CHANGES the
    # operable is still validated (on create the attribute goes nil -> value, so
    # it reads as changed), and a legacy row can never be re-pointed at an
    # unlisted type. Preferred over a point-in-time production survey because it
    # holds whatever the existing data turns out to be.
    validates :operable_type, inclusion: { in: OPERABLE_TYPES }, allow_blank: true,
                              if: :operable_type_changed?
    validates :command, inclusion: { in: COMMANDS }, allow_blank: true,
                        if: :command_changed?
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :progress, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

    # === Event-driven dispatch ===
    after_commit :enqueue_execution, on: :create

    # === Live updates to subscribed clients ===
    after_commit :broadcast_update, on: :update, if: :should_broadcast?

    # === State machine (AASM — platform standard) ===
    # AASM auto-generates predicates (pending?, running?, ...), guard predicates
    # (may_start?, may_complete?, ...), and bang methods (start!, complete!,
    # fail!, abort!, cancel!) that transition or raise AASM::InvalidTransition
    # under `whiny_transitions: true`.
    #
    # Each event mutates audit/timestamp attributes inline via `before` so the
    # final `save!` AASM performs persists everything atomically.
    aasm column: :status, whiny_transitions: true do
      state :pending, initial: true
      state :scheduled
      state :running
      state :complete
      state :failed
      state :aborted
      state :cancelled

      event :schedule do
        transitions from: :pending, to: :scheduled
      end

      event :start do
        transitions from: [ :pending, :scheduled ], to: :running

        before do
          self.started_at = Time.current
          self.progress = 0
          stage_event("started", "Operation started")
        end
      end

      event :complete do
        transitions from: :running, to: :complete

        before do
          self.completed_at = Time.current
          self.progress = 100
          stage_event("completed", "Operation completed successfully")
        end
      end

      event :fail do
        transitions from: :running, to: :failed

        before do |message = nil|
          self.completed_at = Time.current
          self.error_message = message
          stage_event("failed", message || "Operation failed")
        end
      end

      event :abort do
        transitions from: :running, to: :aborted

        before do |message = nil|
          self.completed_at = Time.current
          self.error_message = message
          stage_event("aborted", message || "Operation aborted")
        end
      end

      event :cancel do
        transitions from: [ :pending, :scheduled ], to: :cancelled

        before do |message = nil|
          self.completed_at = Time.current
          self.error_message = message
          stage_event("cancelled", message || "Operation cancelled")
        end
      end
    end

    # === Scopes ===
    scope :by_status, ->(status) { where(status: status) }
    scope :pending, -> { by_status("pending") }
    scope :scheduled, -> { by_status("scheduled") }
    scope :running, -> { by_status("running") }
    scope :complete, -> { by_status("complete") }
    scope :failed, -> { by_status("failed") }
    scope :aborted, -> { by_status("aborted") }
    scope :cancelled, -> { by_status("cancelled") }

    scope :active, -> { where(status: %w[pending scheduled running]) }
    scope :finished, -> { where(status: %w[complete failed aborted cancelled]) }
    scope :exclusive, -> { where(exclusive: true) }
    scope :non_exclusive, -> { where(exclusive: false) }

    scope :for_operable, ->(operable) { where(operable: operable) }
    scope :by_command, ->(command) { where(command: command) }
    scope :recent, -> { order(created_at: :desc) }
    scope :scheduled_before, ->(time) { where("scheduled_at <= ?", time) }

    # === Progress (not a state transition) ===
    def update_progress!(new_progress, message = nil)
      return false unless running?

      stage_event("progress", message || "Progress: #{new_progress}%")
      update!(progress: new_progress.clamp(0, 100), events: events)
      true
    end

    # Public event-append API. Used by callers that aren't inside an AASM
    # transition (controllers, dispatcher recovery paths). Saves immediately.
    # Inside an AASM `before` block, prefer `stage_event` so the single
    # transition save persists everything atomically.
    def add_event(event_type, message, data = {})
      new_event = stage_event(event_type, message, data)
      save! if persisted?
      new_event
    end

    def last_event
      events&.last
    end

    # === Duration ===
    def duration
      return nil unless started_at
      end_time = completed_at || Time.current
      end_time - started_at
    end

    def duration_formatted
      return nil unless duration
      hours = (duration / 3600).to_i
      minutes = ((duration % 3600) / 60).to_i
      seconds = (duration % 60).to_i

      if hours.positive?
        "#{hours}h #{minutes}m #{seconds}s"
      elsif minutes.positive?
        "#{minutes}m #{seconds}s"
      else
        "#{seconds}s"
      end
    end

    # === Lifecycle category checks ===
    def active?
      %w[pending scheduled running].include?(status)
    end

    def finished?
      %w[complete failed aborted cancelled].include?(status)
    end

    private

    # Append an audit event to `events` in memory. Does NOT save — caller
    # is responsible for persisting via the surrounding save (AASM's
    # transition save, or an explicit `update!`/`save!`). Returns the
    # constructed event hash so `add_event` can return it to its caller.
    def stage_event(event_type, message, data = {})
      new_event = {
        type: event_type,
        message: message,
        timestamp: Time.current.iso8601,
        data: data
      }
      self.events = (events || []) + [ new_event ]
      new_event
    end

    def enqueue_execution
      return unless status == "pending"

      # Direct Redis push (Sidekiq client gem is intentionally not bundled
      # server-side — see System::WorkerDispatch for the rationale).
      System::WorkerDispatch.enqueue_operation_execution(id)
    rescue StandardError => e
      # Redis blip, etc. — the hourly SystemTaskReaperJob picks up any
      # operation still in "pending" state past its grace window.
      Rails.logger.warn("[Operation##{id}] Failed to enqueue execution: #{e.message}")
    end

    def should_broadcast?
      saved_change_to_status? || saved_change_to_progress?
    end

    # Per-task progress broadcasts are throttled to one per
    # BROADCAST_THROTTLE_SEC seconds across the cluster — a worker emitting
    # `update_progress!(20)` then `update_progress!(50)` within the window
    # produces one socket message, not two. Status transitions bypass the
    # throttle so terminal events (complete, failed, aborted) always
    # propagate immediately, and they reset the throttle so a follow-up
    # progress tick can fire without waiting for the prior slot to expire.
    BROADCAST_THROTTLE_SEC = 1

    def broadcast_update
      return unless account
      return unless defined?(SystemChannel)

      if saved_change_to_status?
        SystemChannel.broadcast_task_update(account, self)
        Rails.cache.delete(broadcast_throttle_key)
      elsif saved_change_to_progress?
        return unless claim_broadcast_slot
        SystemChannel.broadcast_task_progress(account, self)
      end
    rescue StandardError => e
      Rails.logger.warn("[Task##{id}] Broadcast failed: #{e.message}")
    end

    # Atomic single-writer claim across processes. `unless_exist: true` is
    # the documented Rails.cache idiom for compare-and-swap creation —
    # backed by SETNX on Redis, atomic insert on memory_store.
    def claim_broadcast_slot
      Rails.cache.write(
        broadcast_throttle_key,
        "1",
        expires_in: BROADCAST_THROTTLE_SEC.seconds,
        unless_exist: true
      )
    end

    def broadcast_throttle_key
      "system:task:#{id}:broadcast_throttle"
    end
  end
end
