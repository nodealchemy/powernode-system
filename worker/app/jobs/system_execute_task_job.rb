# frozen_string_literal: true

# Executes a single System::Task by triggering server-side runtime via
# the worker_api. Event-driven: enqueued by Operation's after_commit callback,
# never by a cron poll.
#
# Flow:
#   1. Operation is created with status: "pending"
#   2. Operation#after_commit enqueues this job
#   3. This job POSTs to /api/v1/system/worker_api/operations/:id/execute
#   4. Server-side ExecutionDispatcher claims the op (start!), runs the
#      matching runtime service, and transitions to complete/failed before
#      returning the response.
#
# Idempotency: the server's claim transition (Operation#start!) returns 409
# Conflict if the op is no longer pending/scheduled, so re-running this job
# for an already-completed operation is a graceful no-op.
#
# No retries: sidekiq_options retry: 0 keeps the operation state machine as
# the sole source of truth — Sidekiq retries would risk double execution.
# SystemTaskReaperJob (hourly) is the recovery path for missed enqueues
# and worker crashes mid-execution.
class SystemExecuteTaskJob < BaseJob
  sidekiq_options queue: "system", retry: 0

  def execute(operation_id)
    log_info("[SystemExecute] Starting", operation_id: operation_id)

    response = api_client.post(
      "/api/v1/system/worker_api/operations/#{operation_id}/execute"
    )

    task_status = response.dig("data", "task", "status")
    log_info(
      "[SystemExecute] Completed",
      operation_id: operation_id,
      task_status: task_status,
      runtime_success: response.dig("data", "runtime_result", "success")
    )
    response
  rescue BackendApiClient::ApiError => e
    if e.respond_to?(:status) && e.status == 409
      # Already claimed by another worker, or not in a claimable state — fine.
      log_info(
        "[SystemExecute] Skipped: 409 Conflict (already claimed)",
        operation_id: operation_id
      )
      { skipped: true, reason: "already_claimed" }
    else
      log_error("[SystemExecute] API error", e, operation_id: operation_id)
      raise # retry: 0 means Sidekiq won't retry; reaper handles recovery
    end
  end
end
