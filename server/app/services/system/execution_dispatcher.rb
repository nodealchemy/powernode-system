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
    COMMAND_REGISTRY = {
      "provision"      => System::Runtime::ProvisionInstance,
      "deprovision"    => System::Runtime::ControlInstance, # alias for terminate
      "start"          => System::Runtime::ControlInstance,
      "stop"           => System::Runtime::ControlInstance,
      "restart"        => System::Runtime::ControlInstance,
      "reboot"         => System::Runtime::ControlInstance,
      "terminate"      => System::Runtime::ControlInstance,
      "associate_public_ip"    => System::Runtime::ManagePublicIp,
      "disassociate_public_ip" => System::Runtime::ManagePublicIp,
      "sync_modules"   => System::Runtime::SyncModules,
      "apply_config"   => System::Runtime::ApplyConfig,
      "build_module"   => System::Runtime::BuildModule,
      "commit_module"  => System::Runtime::CommitModule,
      "attach_volume"  => System::Runtime::AttachVolume,
      "detach_volume"  => System::Runtime::DetachVolume,
      "ssh_command"    => System::Runtime::ExecuteSshCommand,
      "sync"           => System::Runtime::SyncCloudState
    }.freeze

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
        return Outcome.new(claimed: true, result: result, status_code: :unprocessable_entity)
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
