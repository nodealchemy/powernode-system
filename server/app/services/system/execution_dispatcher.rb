# frozen_string_literal: true

module System
  # Maps an Operation's command to the runtime service that executes it,
  # and orchestrates the claim → run → transition flow.
  #
  # Called from Api::V1::System::WorkerApi::TasksController#execute,
  # which is itself triggered by SystemExecuteTaskJob in the worker.
  # The dispatch chain is fully event-driven: an Operation's after_commit
  # callback enqueues the job; the job calls /execute; this dispatcher runs
  # the work and writes back final state.
  class ExecutionDispatcher
    class UnsupportedCommandError < StandardError; end

    # Frozen registry of command → runtime service class.
    # The registry is the single source of truth for "what does each command do."
    # Adding a new command requires adding the runtime class AND registering it here.
    # WHAT WAS REMOVED, AND WHY (dispatch-spine decision step 3, knowledge
    # 01a031f2). NINE verbs are gone: provision, deprovision,
    # associate_public_ip, disassociate_public_ip, attach_volume, detach_volume,
    # build_module, commit_module, sync.
    #
    # Two independent properties had to hold for each, and the second is the one
    # that actually licenses a deletion:
    #
    #   UNUSED — measured against the whole task table, not a recent window: 476
    #   System::Task rows have ever existed, across exactly SIX distinct commands
    #   (apply_config 263, sync_modules 100, ci.module_build 65,
    #   upgrade_boot_image 26, restart 18, ssh_command 4). Every deleted verb has
    #   a lifetime count of ZERO.
    #
    #   UNREACHABLE — no code path constructs one. This is the harder half and
    #   the first pass got it wrong: a producer can pass the command as a
    #   VARIABLE, which no literal `command: "..."` grep will ever surface.
    #   start/stop/reboot/terminate were retired on the strength of the row count
    #   alone and had to be restored (see below). The nine above were re-checked
    #   for variable producers too — the only ones that exist are
    #   NodeInstanceGating (start/stop/reboot/terminate), ModuleBuildBatch
    #   #member_task_command (ci.module_build / ci.package_build), DecisionEngine
    #   (sync_modules / apply_config) and the storage managers (storage.*).
    #   None of them can emit any of the nine.
    #
    # The provider plane the nine nominally owned is really performed by
    # MCP tool -> ProvisioningService / InstanceControlService against the
    # provider adapters with no Task involved, so nothing is lost.
    #
    # The provider plane these verbs nominally owned is really performed by
    # MCP tool -> System::ProvisioningService / InstanceControlService, calling
    # the provider adapters directly, with no Task involved. Deleting them
    # removes no capability; it removes a second, unreachable way to do what
    # already works. They are DELETED rather than left inert because an
    # unreachable branch that looks reachable is what produced the whole
    # dispatch-spine investigation in the first place.
    #
    # RESTORED, same day, after they were wrongly retired:
    # start/stop/reboot/terminate. Api::V1::System::NodeInstanceGating
    # #control_or_error calls create_instance_operation(event.to_s), so the
    # command is a VARIABLE — invisible to a literal grep, which is how the
    # first pass concluded they had no producer.
    #
    # For a CLOUD provider this registry IS their execution path: that concern
    # fires the provider call in-thread only for local_qemu and explicitly
    # leaves everything else to the worker queue. Retiring them broke instance
    # control for every non-local provider — invisible on this fleet, which is
    # all local_qemu, and precisely the kind of latent break that only surfaces
    # on someone else's deployment.
    #
    # (Known, pre-existing, filed separately: on local_qemu the task is created
    # `pending` AND the provider call fires in-thread, so dispatch double-acts.
    # That is a defect in the PRODUCER, not a reason to unregister the verbs.)
    #
    # `restart` is likewise KEPT despite its server-side arm never having fired
    # (all 18 restart rows carry options["unit"] and route to the agent). Step 2
    # of that decision has since landed: the unit-vs-VM choice is now DECLARED
    # by the producer (System::Task::RESTART_SCOPES) instead of inferred from an
    # absent key, so the server-side arm is reachable only on purpose.
    COMMAND_REGISTRY = {
      "start"          => System::Runtime::ControlInstance,
      "stop"           => System::Runtime::ControlInstance,
      "reboot"         => System::Runtime::ControlInstance,
      "terminate"      => System::Runtime::ControlInstance,
      "restart"        => System::Runtime::ControlInstance,
      "sync_modules"   => System::Runtime::SyncModules,
      "apply_config"   => System::Runtime::ApplyConfig,
      "ssh_command"    => System::Runtime::ExecuteSshCommand
    }.freeze

    # Commands executed ON THE NODE by the powernode-agent, which polls
    # node_api for its pending tasks and reports its own completion there.
    # The server-side dispatcher must NOT claim/run/fail these — it leaves them
    # `pending` for the agent to pick up. Without this, an agent-delegated task
    # is rejected as "Unsupported command" and failed within milliseconds of
    # creation (the after_commit enqueue fires immediately), long before the
    # agent's next poll — so the node never sees it. These are exactly the
    # agent-side task handlers (see the agent's tasks/handlers registry) that
    # have no COMMAND_REGISTRY entry above.
    #
    # ci.module_build (campaign 019f5885 inc7): the agent, on a leased
    # module-forge builder, pulls its build secrets from the lease-gated
    # Api::V1::System::NodeApi::ConfigController#ci_build_context endpoint
    # and execs /usr/local/bin/module-forge-build.sh — see
    # agent/internal/runtime/tasks/handlers/module_build.go. No handler
    # timeout on the poll loop, so a long native build is fine.
    #
    # ci.package_build (campaign 019f6084 inc-D): the SAME lease-gated build
    # path for a materialized package closure (which has no git tree) — the
    # agent execs /usr/local/bin/module-forge-package-build.sh; see
    # agent/internal/runtime/tasks/handlers/package_build.go. Without this
    # delegation entry the dispatcher rejects the Task server-side before the
    # agent's lease loop ever polls it.
    #
    # probe.module_smoke (campaign 019f6084 inc-E): the agent runs
    # structured post-compose health checks (systemd unit active, health
    # endpoint, ldd closure) on ITS OWN instance via
    # agent/internal/runtime/tasks/handlers/probe_module_smoke.go —
    # System::ModuleSmokeProbe dispatches + bounded-polls this Task.
    AGENT_DELEGATED_COMMANDS = %w[
      upgrade_boot_image
      a2a_call
      storage.mount storage.unmount storage.exports.apply storage.smb_user.apply
      storage.gateway.provision storage.gateway.deprovision storage.chown
      ci.module_build
      ci.package_build
      probe.module_smoke
    ].freeze

    # @param options [Hash, nil] the task's options JSONB. Optional so the
    #   pre-existing single-argument call shape keeps working unchanged.
    def self.agent_delegated?(command, options = nil)
      AGENT_DELEGATED_COMMANDS.include?(command) || unit_scoped_restart?(command, options)
    end

    # A `restart` task means two entirely different things, and the two
    # terminal functions are on opposite sides of the fleet:
    #
    #   scope "unit"     — only the agent can do this (tasks/handlers/
    #     lifecycle.go LifecycleHandler reads options["unit"] and shells out to
    #     `systemctl restart`).
    #   scope "instance" — COMMAND_REGISTRY routes it to Runtime::ControlInstance,
    #     whose ACTION_FOR_COMMAND maps "restart" to the "reboot" action:
    #     InstanceControlService reboots the WHOLE VM through the provider
    #     adapter.
    #
    # The agent dispatches on the LITERAL command string (tasks.Registry
    # #Lookup), so "restart" is the only command that reaches the systemd
    # handler — the collision is not avoidable by picking a different name,
    # and the agent must not be changed. Since System::Task's after_commit
    # enqueues server-side execution on create, without this split a
    # unit-scoped restart would reboot the VM *and* restart the unit.
    #
    # Deliberately NOT extended to reboot/terminate — those have no
    # unit-scoped meaning, and RebootHandler ignores options entirely.
    def self.unit_scoped_restart?(command, options)
      command == "restart" && restart_scope(options) == "unit"
    end

    # The DECLARED scope, with an explicit and dated legacy fallback.
    #
    # System::Task now REFUSES to create a restart that does not declare
    # System::Task::RESTART_SCOPE_KEY, so every row minted from here on names
    # the actuator it means rather than leaving this dispatcher to guess from
    # an incidental key. Rows created BEFORE that validation cannot declare
    # one and some are still in flight, so their scope is inferred exactly the
    # way the whole routing decision used to be made: a named unit means the
    # agent, and nothing else can be assumed about them.
    #
    # That fallback is unreachable for new rows by construction — it is dated
    # by the model validation, not by a point-in-time survey of the table —
    # and it preserves the routing of every row that exists today unchanged.
    def self.restart_scope(options)
      opts = options.is_a?(Hash) ? options : {}
      declared = opts[::System::Task::RESTART_SCOPE_KEY].to_s
      return declared if ::System::Task::RESTART_SCOPES.include?(declared)

      opts["unit"].present? ? "unit" : "instance"
    end

    Outcome = Struct.new(:claimed, :result, :status_code, keyword_init: true)

    # @param operation [System::Task]
    # @param worker [Worker, nil] the worker claiming this operation
    # @return [Outcome] with claimed (bool), result (Runtime::Result), status_code (HTTP)
    def self.run(operation, worker: nil)
      new(operation, worker: worker).run
    end

    def initialize(operation, worker: nil)
      @operation = operation
      @worker = worker
    end

    def run
      # Node-executed commands are left pending for the powernode-agent to poll
      # and complete via node_api. The server neither claims nor fails them.
      if self.class.agent_delegated?(@operation.command, @operation.options)
        log_event(:dispatch_delegated_to_agent, command: @operation.command)
        return Outcome.new(
          claimed: false,
          result: System::Runtime::Result.ok(data: { delegated_to_agent: true, command: @operation.command }),
          status_code: :accepted
        )
      end

      service_class = COMMAND_REGISTRY[@operation.command]

      unless service_class
        # AASM `fail!` requires the op to be running; an unsupported command
        # is rejected before we ever transition past pending. Take it through
        # `start!` first (forces it to running), then `fail!` records the
        # rejection through the platform-standard state machine path.
        message = "Unsupported command: #{@operation.command}"
        log_event(:dispatch_rejected, command: @operation.command, reason: message)
        if @operation.may_start?
          claim_for_dispatcher
          @operation.start!
        end
        @operation.fail!(message) if @operation.may_fail?
        result = System::Runtime::Result.err(error: message)
        return Outcome.new(claimed: true, result: result, status_code: :unprocessable_content)
      end

      # Atomic claim via AASM transition. `may_start?` is the platform-standard
      # pre-flight; if the op isn't in pending/scheduled, another worker already
      # claimed it (or it was completed/cancelled). 409 Conflict communicates
      # to the caller that this is not a retryable failure.
      unless @operation.may_start?
        log_event(:dispatch_conflict, status: @operation.status)
        return Outcome.new(
          claimed: false,
          result: System::Runtime::Result.err(
            error: "Operation cannot be started from #{@operation.status} state"
          ),
          status_code: :conflict
        )
      end
      claim_for_dispatcher
      @operation.start!

      log_event(:dispatch_started, runtime: service_class.name)
      started_at = Time.current
      result = service_class.call(operation: @operation.reload)
      duration_ms = ((Time.current - started_at) * 1000).round

      if result.success?
        @operation.complete!
        log_event(:dispatch_complete, duration_ms: duration_ms)
      else
        @operation.fail!(result.error)
        log_event(:dispatch_failed, duration_ms: duration_ms, error: result.error)
      end

      Outcome.new(claimed: true, result: result, status_code: :ok)
    rescue StandardError => e
      Rails.logger.error(
        "[ExecutionDispatcher] #{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}"
      )
      log_event(:dispatch_exception, exception: e.class.name, error: e.message)
      @operation.fail!("Dispatcher exception: #{e.message}") if @operation.may_fail?
      Outcome.new(
        claimed: true,
        result: System::Runtime::Result.err(
          error: "Dispatcher exception: #{e.message}",
          data: { exception: e.class.name }
        ),
        status_code: :internal_server_error
      )
    end

    private

    # Stamp the worker that's about to run this operation. Sets the column
    # in memory; the AASM `start!` save persists it alongside the state
    # transition. If no worker context is available (rare — direct dispatcher
    # invocation from a Rails console), the column stays null.
    def claim_for_dispatcher
      return unless @worker
      @operation.claimed_by_worker_id = @worker.id
    end

    # Emit a structured log line for observability tooling. Designed to be
    # cheap and side-effect-free so it can be safely sprinkled in the hot
    # path. Future Prometheus/StatsD wiring can subscribe to ActiveSupport
    # notifications keyed on "system.dispatch" without changing this code.
    def log_event(event, **details)
      payload = {
        event: "system.dispatch.#{event}",
        task_id: @operation.id,
        command: @operation.command,
        account_id: @operation.account_id,
        worker_id: @worker&.id
      }.merge(details)

      Rails.logger.info(payload.to_json)
      ActiveSupport::Notifications.instrument("system.dispatch.#{event}", payload)
    rescue StandardError => e
      # Never let observability failures break the dispatch path.
      Rails.logger.warn("[ExecutionDispatcher] log_event failed: #{e.message}")
    end
  end
end
