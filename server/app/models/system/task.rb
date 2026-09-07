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
    # Every one of these COMMANDS is executed by the ON-NODE AGENT and by nothing
    # else. (Per command, not per row — see the delivery qualifier below.)
    # Campaign 01a0790b increment 3 retired the server dispatch arm and with it
    # System::ExecutionDispatcher, so the split this list used to be defined by
    # — COMMAND_REGISTRY.keys (server-dispatched) UNION AGENT_DELEGATED_COMMANDS
    # (node-executed) — no longer exists. There is one lane.
    #
    # THE ORACLE MOVED, AND GOT STRONGER. That old equality compared two Ruby
    # constants in this repo, so a single edit could shuffle a command between
    # the lists and keep them agreeing while the platform's ability to EXECUTE
    # it changed — a control that describes itself. The replacement,
    # spec/lint/agent_handles_every_task_command_spec.rb, reads the AGENT'S OWN
    # handler registry out of the Go source and asserts this list is a SUBSET of
    # it. Subset, not equality: the agent registers verbs the platform never
    # mints (terminate, provision, deprovision, sync, custom), and an extra
    # handler is inert while a missing one is a row that can never complete.
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
    # `terminate` LEFT this list in campaign 01a0790b increment 2. The platform
    # means "destroy the instance"; the agent — now the sole actuator of a Task
    # — registers it to RebootHandler and runs `systemctl reboot`
    # (tasks/handlers/lifecycle.go:121-124: "The agent treats it as reboot"), so
    # the machine came back and the row stuck in `terminating`. Destroying an
    # instance is System::Executors::TerminateInstance's job, which both the
    # REST and MCP surfaces now use and which carries the four controls this
    # lane dropped. Removed from ExecutionDispatcher::COMMAND_REGISTRY in the
    # same commit; that registry has since been deleted outright (increment 3),
    # and the agent still registers `terminate` — harmlessly, since nothing can
    # mint one. The ledger example in the lint spec above records it.
    COMMANDS = %w[
      start stop restart reboot
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

    # `restart` is the one command whose NAME does not say what it does, and its
    # two readings sit at opposite ends of the blast-radius scale:
    #
    #   unit     — restart ONE systemd unit on the node. Only the agent can do
    #              this (tasks/handlers/lifecycle.go LifecycleHandler shells out
    #              to `systemctl restart options["unit"]`).
    #   instance — REBOOT THE WHOLE VM. This reading is GONE twice over: the
    #              scope left RESTART_SCOPES in increment 2, and increment 3
    #              deleted the route that gave it meaning (COMMAND_REGISTRY ->
    #              Runtime::ControlInstance -> the provider adapter). It is
    #              described here because the hazard below is why the scope must
    #              still be DECLARED, not because either half survives.
    #
    # On a self-hosted control plane that second reading takes down the platform
    # issuing the command.
    #
    # The scope used to be INFERRED, downstream, from whether options["unit"]
    # happened to be set — which made the destructive reading the DEFAULT for
    # anyone who did not know the convention. `POST /api/v1/system/tasks` with
    # `{command: "restart"}`, the obvious way to ask for a service bounce,
    # rebooted the machine, and nothing in the request said so. The producer now
    # DECLARES its scope and an undeclared restart is refused at the model, which
    # is the only chokepoint every producer passes through (the HTTP create path,
    # the worker API, the MCP tools and ~15 in-process callers all reach save).
    # NARROWED to `unit` in campaign 01a0790b increment 2. The `instance`
    # reading — reboot the whole VM through the provider — was dead on BOTH
    # sides: the server dispatch arm 404s for every task id, and the agent's
    # LifecycleHandler refuses a restart with no options["unit"] at
    # validateUnit. No producer in the tree ever declared it (the only restart
    # producer is System::RestartAfterUpdate, scope "unit"), so nothing is
    # taken away. A caller who wants the VM power-cycled has `reboot` — which
    # is what the refusal message below already told them to use.
    RESTART_SCOPE_KEY = "scope"
    RESTART_SCOPES = %w[unit].freeze

    # Records that may legitimately carry a task.
    #
    # operable_type is free text on an open polymorphic belongs_to, and
    # `optional: true` means an unresolvable pair persists silently, so without
    # this a caller naming any model at all (Account, User, Ai::Agent) gets it
    # stored verbatim.
    #
    # The enumeration is the UNION of two sources, and neither alone is
    # complete: the models declaring the inverse `has_many :tasks, as: :operable`,
    # plus the types the retired server-side runtime dispatchers accepted —
    # System::Runtime::SyncCloudState handled a ProviderRegion, which declares
    # no inverse at all, and that is why the type is listed here with no
    # corresponding association.
    #
    # THE SECOND SOURCE IS NOW HISTORY, AND THAT MATTERS. This comment used to
    # end "adding a dispatch arm without listing it here fails closed at
    # validation". There are no dispatch arms: campaign 01a0790b increment 3
    # deleted the last of them. Delivery is `current_instance.tasks`
    # (NodeApi::StatusController#pending_tasks), so of the seven types below
    # exactly ONE — System::NodeInstance — can carry a row that reaches an
    # executor. The other six are accepted by this validation and served to
    # nothing.
    #
    # Left as-is rather than narrowed in increment 3: narrowing OPERABLE_TYPES
    # is a contract change on POST /api/v1/system/tasks that needs its own
    # red-first test and its own decision about pre-existing rows, not a rider
    # on a deletion. Filed separately.
    OPERABLE_TYPES = %w[
      System::Node
      System::NodeInstance
      System::Provider
      System::ProviderNetwork
      System::ProviderRegion
      System::ProviderVolume
      System::ProviderVolumeSnapshot
    ].freeze

    # The two on-node reconcile commands: an agent polls its own pending rows
    # (Api::V1::System::NodeApi::StatusController#pending_tasks) and runs them
    # on the node, so a row minted for an instance with no live agent sits at
    # pending / progress 0 until the worker janitor cancels it, with nothing in
    # the event stream saying why. NodeInstance#on_node_dispatch_refusal carries
    # the evidence; spec/lint/on_node_task_producer_census_spec.rb censuses
    # everything that constructs one.
    #
    # THE HEDGE THAT CENSUS FILE KEEPS, kept here too rather than dropped:
    # "no agent will pull this" is literally true of the AGENT_DELEGATED set and
    # only EMPIRICALLY true of these two. ExecutionDispatcher::COMMAND_REGISTRY
    # still maps both to server-side System::Runtime classes, and that arm is
    # dead for a DATA reason (System::Node#worker_id is NULL fleet-wide, so
    # WorkerApi::TasksController#execute's #worker_operations scope is empty and
    # every lookup 404s) rather than a structural one. Stated as a DATA STATE
    # deliberately, the way NodeInstance#on_node_dispatch_refusal states it:
    # worker_id is a permitted attribute on the node create/update MCP verbs, so
    # one call can falsify the sentence; what cannot change by a single call is
    # that nothing in the tree assigns it. The challenge was RAISED as offer
    # 01a07861-96d8 — whose title asserts the opposite, because it records the
    # question — and resolved against it; read the resolution, not the title.
    #
    # DELIBERATELY NOT the same set as the agent-delegated commands
    # (upgrade_boot_image, the storage.* verbs, ci.*, probe.module_smoke).
    # Those are also agent-pulled, and whether the gate should extend to them
    # is the same filed question, not an omission here.
    ON_NODE_RECONCILE_COMMANDS = %w[sync_modules apply_config].freeze

    # Raised when a producer is asked to mint an ON_NODE_RECONCILE_COMMANDS row
    # for a target whose agent will never pull it. Carries the refusal
    # NodeInstance#on_node_dispatch_refusal produced, verbatim, so the operator
    # reads the reason rather than a generic failure.
    UndeliverableOnNodeTask = Class.new(StandardError)

    # Raised instead of a bare CrossAccountError when the TYPE is refused
    # rather than the owner. It subclasses so existing rescues and log greps
    # keep working, while a genuine cross-tenant signal stays undiluted.
    BadOperableType = Class.new(::Ai::DeferredOperation::CrossAccountError)

    # === The on-node liveness seam (IMP-93d9f4a31627) ===
    #
    # ONE implementation, consulted from two moments: Api::V1::System::
    # TasksController#create refuses before the autonomy gate (so the operator
    # gets the reason, and no DeferredOperation or approval is written for work
    # that can never run), and System::Executors::ExecuteTask#perform refuses
    # again immediately before constructing the row — which is the load-bearing
    # one, because an approved operation replays straight into #perform with no
    # controller in the path. Gating only where the request arrives would
    # grandfather the replay, the defect an independent review found in a
    # sibling guard whose mint paths were fixed and whose lifecycle verbs were
    # not.
    #
    # Shared rather than written twice because the OPERABLE ANALYSIS below is
    # the part that is easy to get wrong, and a second copy would have drifted
    # the first time either arm changed.

    # The reason an on-node reconcile aimed at `operable` would never be pulled,
    # or nil. Nil for every command outside ON_NODE_RECONCILE_COMMANDS.
    #
    # TWO OPERABLE SHAPES, because both are real and only one was gated first:
    #
    #   NodeInstance — the agent polls its OWN pending rows, so the instance's
    #     own predicate is the answer.
    #   Node — System::Runtime::SyncModules fans a Node operable out across
    #     `node.node_instances`, so the question is whether ANY of them could
    #     act on it. Refused only when the node has instances and EVERY one is
    #     refused: a node with one live instance and three dead ones still has
    #     work to do, and refusing it would be worse than the stuck row.
    #
    # A nil operable, and every other OPERABLE_TYPES member, answer nil: there
    # is no agent to ask about. That is NOT a claim such a row is deliverable —
    # delivery is per-instance (StatusController#pending_tasks serves
    # `current_instance.tasks`), so a Node-operable row reaches no agent at all
    # whatever its instances' liveness. That is a different defect with a
    # different fix, filed as offer 01a079f5-2322, and this predicate
    # deliberately does not pretend to answer it.
    ON_NODE_LIVENESS_OPERABLE_TYPES = %w[System::NodeInstance System::Node].freeze

    def self.undeliverable_on_node_refusal(command:, operable:)
      on_node_liveness_answer(command: command, operable: operable,
                              summary: "unreachable") do |instance|
        instance.on_node_dispatch_refusal
      end
    end

    # The DISCLOSURE arm, same shape. NodeInstance#dormant_agent_reason covers
    # the statuses that are live for capacity but are running no agent YET
    # (stopped / rebooting / provisioning): the task is the right thing to queue
    # and IS pulled when an agent starts, so this must never be used to refuse —
    # only to stop a surface reporting a bare success it cannot justify.
    def self.dormant_on_node_reason(command:, operable:)
      on_node_liveness_answer(command: command, operable: operable,
                              summary: "running no agent yet") do |instance|
        instance.dormant_agent_reason
      end
    end

    # `summary` is the caller's word for what its arm found, because the two
    # arms mean OPPOSITE things: a refusal says the agents are gone, a
    # disclosure says they have not started. One shared tail reading
    # "unreachable" for both put refusal vocabulary on a 201 response.
    #
    # DISPATCHES ON CLASS, not on respond_to?. Duck typing was tried and is
    # wrong in both directions here: an inline
    # `respond_to?(:on_node_dispatch_refusal)` fell OPEN on a Node operable,
    # and `respond_to?(:node_instances)` then fell BROAD — System::ProviderRegion
    # is an OPERABLE_TYPES member that also declares `has_many :node_instances`,
    # so a region operable would have been fanned out across every instance in
    # the region on a request path, to answer a question no dispatcher acts on
    # (Runtime::SyncModules handles NodeInstance and Node and errors on
    # everything else). ON_NODE_LIVENESS_OPERABLE_TYPES is the one list, and
    # TasksController consumes it rather than keeping a second copy.
    def self.on_node_liveness_answer(command:, operable:, summary:)
      return nil unless ON_NODE_RECONCILE_COMMANDS.include?(command.to_s)

      case operable
      when ::System::NodeInstance
        yield(operable)
      when ::System::Node
        # The empty case answers nil rather than refusing: a node with no
        # instances is not evidence of a dead agent.
        instances = operable.node_instances.to_a
        return nil if instances.empty?

        answers = instances.map { |instance| [ instance, yield(instance) ] }
        return nil unless answers.all? { |_, answer| answer.present? }

        "every instance of #{operable.class.name}##{operable.id} is #{summary}: " +
          answers.map { |instance, answer| "#{instance.name}: #{answer}" }.join("; ")
      end
    end
    private_class_method :on_node_liveness_answer

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
    # Same CHANGE-guarded shape as operable_type, for the same reason: restart
    # rows minted before the declaration existed cannot carry one, and some are
    # in flight. See #restart_scope_declared.
    validate :restart_scope_declared, if: :restart_scope_validatable?
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :progress, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

    # === Dispatch: NONE. ===
    # This model used to carry `after_commit :enqueue_execution, on: :create`,
    # which LPUSHed a SystemExecuteTaskJob so the worker could call
    # worker_api/tasks/:id/execute. Campaign 01a0790b increment 3 retired that
    # whole arm: it 404'd for every task id (its controller scoped through
    # System::Node.where(worker: current_worker) and no node has ever had a
    # worker), and the on-node agent — which is offered every pending row by
    # NodeApi::StatusController#pending_tasks, with no command filter — was
    # already the only thing executing these.
    #
    # A Task is now a MESSAGE TO THE AGENT ON ITS INSTANCE. It is created and
    # left `pending`; that instance's agent polls, runs it, and reports its own
    # completion. Nothing server-side claims it. See spec/lint/
    # agent_handles_every_task_command_spec.rb, which pins that the agent has a
    # handler for every command this model can mint.
    #
    # THE QUALIFIER IS LOAD-BEARING. Delivery is
    # NodeApi::StatusController#pending_tasks, which reads
    # `current_instance.tasks` — so only a row whose `operable` IS the
    # NodeInstance is ever offered to anything. OPERABLE_TYPES below still
    # admits System::Node and five Provider* types; a row against one of those
    # reaches no agent and no server, and waits for the reaper to cancel it.
    # Every in-app producer targets an instance, so this is a latent shape
    # rather than a live defect — but "a Task is a message to the agent" is
    # true of the COMMAND SET, not of every row this model will accept.

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

    # Only when the command or the options are being SET or CHANGED. A restart
    # row written before RESTART_SCOPE_KEY existed cannot declare one, and
    # validating unconditionally would make it unsaveable — bricking the
    # progress ticks and the fail!/complete!/abort! transitions of restarts a
    # node is already mid-flight on. (RestartAfterUpdate settles its own rows
    # with update_columns, which bypasses validation entirely, but the AASM
    # transitions go through a normal save.) The property still holds for every
    # new row: on create the command goes nil -> value, which reads as changed.
    def restart_scope_validatable?
      command == "restart" && (will_save_change_to_command? || will_save_change_to_options?)
    end

    # Refuses a restart that does not say which actuator it means. The two
    # readings are documented on RESTART_SCOPES above; the point of the
    # validation is that neither one is a DEFAULT.
    def restart_scope_declared
      opts = options.is_a?(Hash) ? options : {}
      declared = opts[RESTART_SCOPE_KEY].to_s
      unit = opts["unit"]

      unless RESTART_SCOPES.include?(declared)
        errors.add(
          :options,
          %(must declare ["#{RESTART_SCOPE_KEY}"] on a "restart" task: ) +
          %("unit" restarts ONE systemd unit on the node (also set ["unit"]), ) +
          %("instance" REBOOTS THE WHOLE VM. Got #{declared.presence.inspect}. ) +
          %(If you mean a VM reboot, prefer the unambiguous "reboot" command.)
        )
        return
      end

      if declared == "unit" && unit.blank?
        errors.add(:options, %(must name the systemd unit in ["unit"] when ["#{RESTART_SCOPE_KEY}"] is "unit"))
      elsif declared == "instance" && unit.present?
        errors.add(
          :options,
          %(must not also name ["unit"] (#{unit.inspect}) when ["#{RESTART_SCOPE_KEY}"] is ) +
          %("instance" — the VM reboots and that unit is never restarted)
        )
      end
    end

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
