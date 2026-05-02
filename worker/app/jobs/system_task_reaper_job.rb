# frozen_string_literal: true

# Hourly safety net for the System operation dispatch chain.
#
# The primary dispatch path is event-driven (Operation#after_commit on :create
# enqueues SystemExecuteTaskJob). This reaper exists to catch the rare
# cases the primary path misses:
#   1. Operation created during a Redis blip — Sidekiq enqueue threw, caller
#      logged a warning, but the row sits in :pending forever.
#   2. Worker process crashed while holding the connection to /execute —
#      operation got into :running but never transitioned to a terminal state.
#
# This is NOT the primary dispatch path. It runs once an hour. Latency on
# happy-path operations is unaffected.
#
# Design choices:
#   - The reaper is "naive" about claiming: it re-enqueues regular execute
#     jobs and lets the server's atomic claim transition (Operation#start!)
#     decide. Re-enqueueing an already-running op is harmless (server returns
#     409 Conflict; the worker job logs and exits).
#   - Stuck-running threshold is 60 minutes — generous enough that a slow
#     real provisioning isn't false-positively killed. Tune via
#     STUCK_RUNNING_THRESHOLD env if specific commands routinely run longer.
class SystemTaskReaperJob < BaseJob
  sidekiq_options queue: "system", retry: 0

  STUCK_PENDING_THRESHOLD = (ENV.fetch("SYSTEM_REAPER_STUCK_PENDING_MIN", "5").to_i * 60).freeze
  STUCK_RUNNING_THRESHOLD = (ENV.fetch("SYSTEM_REAPER_STUCK_RUNNING_MIN", "60").to_i * 60).freeze

  def execute(*_args)
    log_info("[SystemReaper] Starting reap cycle")

    pending_count = reap_stuck_pending
    running_count = reap_stuck_running

    log_info(
      "[SystemReaper] Reap cycle complete",
      stuck_pending_re_enqueued: pending_count,
      stuck_running_failed: running_count
    )

    { reaped_pending: pending_count, reaped_running: running_count }
  end

  private

  # Pending or scheduled operations whose enqueue might have been missed.
  # Re-issue the regular execute job; idempotency comes from the server's
  # atomic claim (start!) which 409s if the op is no longer claimable.
  def reap_stuck_pending
    response = api_client.get(
      "/api/v1/system/worker_api/tasks",
      { status: "pending", stuck_since: STUCK_PENDING_THRESHOLD, per_page: 100 }
    )
    tasks = response.dig("data", "tasks") || []

    re_enqueued = 0
    tasks.each do |task|
      next unless stuck?(task["created_at"], STUCK_PENDING_THRESHOLD)

      log_warn(
        "[SystemReaper] Re-enqueuing stuck pending task",
        task_id: task["id"],
        created_at: task["created_at"]
      )
      SystemExecuteTaskJob.perform_async(task["id"])
      re_enqueued += 1
    end

    re_enqueued
  rescue BackendApiClient::ApiError => e
    log_error("[SystemReaper] Failed to fetch pending tasks", e)
    0
  end

  # Running tasks whose holding worker has died. We cannot ping the specific
  # worker so we use a generous time-since-started heuristic. Mark them
  # failed with execution_lost so the operator sees the cause.
  def reap_stuck_running
    response = api_client.get(
      "/api/v1/system/worker_api/tasks",
      { status: "running", per_page: 100 }
    )
    tasks = response.dig("data", "tasks") || []

    failed = 0
    tasks.each do |task|
      started_at = task["started_at"]
      next unless stuck?(started_at, STUCK_RUNNING_THRESHOLD)

      log_warn(
        "[SystemReaper] Failing stuck running task",
        task_id: task["id"],
        started_at: started_at
      )
      api_client.post(
        "/api/v1/system/worker_api/tasks/#{task['id']}/fail",
        { error_message: "execution_lost: stuck running > #{STUCK_RUNNING_THRESHOLD / 60} min" }
      )
      failed += 1
    end

    failed
  rescue BackendApiClient::ApiError => e
    log_error("[SystemReaper] Failed to reap stuck running tasks", e)
    0
  end

  def stuck?(timestamp_string, threshold_seconds)
    return false if timestamp_string.blank?
    timestamp = Time.parse(timestamp_string.to_s)
    (Time.current - timestamp) >= threshold_seconds
  rescue ArgumentError
    false
  end
end
