# frozen_string_literal: true

# Hourly safety net for the System task dispatch chain.
#
# WHAT WENT WRONG BEFORE, AND WHY IT WAS INVISIBLE
#
# This job read /api/v1/system/worker_api/tasks, whose scope is
# `System::Node.where(worker: current_worker)`. `node.worker_id` is NULL on
# every node that has ever existed (157/157 on live ops-hub, 2026-08-24) and
# nothing assigns it. The scope resolved to the empty set, so every hourly run
# fetched zero tasks and logged "reap cycle complete, 0, 0" — SUCCESS. It ran
# that way for five weeks while a backlog accumulated, oldest row 2026-07-19.
#
# A janitor that reports success while seeing nothing is indistinguishable from
# a clean fleet. That is the whole failure: not a crash, not an error rate — an
# empty scope wearing a green log line. It is re-homed onto an account-scoped
# seam (worker_api/janitor) whose tenancy anchor is the authenticated worker's
# own account_id, per the dispatch-spine decision (knowledge 01a031f2), which
# explicitly rejects populating node.worker_id to make the old scope true.
#
# WHY RE-ENQUEUE ALONE COULD NEVER DRAIN THE BACKLOG
#
# The old design's only remedy for a stuck :pending task was to re-enqueue
# SystemExecuteTaskJob. For an AGENT-DELEGATED command that is a no-op by
# construction: the dispatcher deliberately left those rows :pending for the
# node agent to poll, so re-enqueuing one changed nothing. If the agent is gone
# — instance terminated, node retired — no amount of re-enqueuing will ever move
# it, and the row waits forever. Since apply_config / ci.module_build /
# sync_modules (agent-delegated) are ~95% of the 30-day task mix, "re-enqueue
# and hope" was never a terminal policy for the common case.
#
# CAMPAIGN 01a0790b INCREMENT 3 FINISHED THAT ARGUMENT. Every command is now
# agent-executed, so the re-enqueue lane was a no-op for ALL of them, not ~95%
# — and the job it fired, along with the server dispatch arm that job called,
# is deleted. LANE 1 WENT WITH THEM. The numbering below is kept as-is rather
# than closed up, because lanes 2 and 3 are named after it in this file and in
# the server-side reap endpoint:
#
#   1. stuck :pending/:scheduled -> re-enqueue          [RETIRED, increment 3]
#   2. stuck :running                                 -> reap (fail)
#   3. stuck beyond UNRUNNABLE_THRESHOLD              -> reap (cancel)
#
# Lane 3 is now the ONLY closer for a stuck :pending row, which is what lane 1's
# own comment already said it was for the agent-delegated majority. It fires
# well past the point where the agent has demonstrably not picked the row up,
# and the server picks fail-vs-cancel from the row's own state (cancel for a
# task that never started — calling it "failed" would assert an execution that
# never happened).
#
# THRESHOLDS
#   (STUCK_PENDING, 5 min, was lane 1's window. Deleted with the lane — an
#    unused threshold constant is exactly the kind of inert-but-plausible
#    artefact that made the dispatch spine look alive for as long as it did.)
#   STUCK_RUNNING   60 min  — generous, so a slow real provisioning is not
#                             false-positively killed.
#   UNRUNNABLE      48 hrs  — nothing is coming for a pending task this old. Set
#                             far above the longest legitimate agent absence (a
#                             node down for a working day) so an offline-but-
#                             returning agent still finds its work waiting.
#                             (This used to read "has survived ~48 re-enqueue
#                             attempts" — there are no re-enqueue attempts any
#                             more, and the number was always a lane-1 artefact
#                             rather than a reason for the threshold.)
class SystemTaskReaperJob < BaseJob
  sidekiq_options queue: "system", retry: 0

  STUCK_RUNNING_THRESHOLD    = (ENV.fetch("SYSTEM_REAPER_STUCK_RUNNING_MIN", "60").to_i * 60).freeze
  UNRUNNABLE_THRESHOLD       = (ENV.fetch("SYSTEM_REAPER_UNRUNNABLE_MIN", "2880").to_i * 60).freeze

  JANITOR_TASKS_PATH = "/api/v1/system/worker_api/janitor/tasks"

  def execute(*_args)
    log_info("[SystemReaper] Starting reap cycle")

    failed    = reap_stuck_running
    cancelled = reap_unrunnable

    log_info(
      "[SystemReaper] Reap cycle complete",
      stuck_running_failed: failed,
      unrunnable_cancelled: cancelled
    )

    # `reaped_pending` is kept in the return shape, always 0, because lane 1 is
    # gone (see below) and a caller reading the old key should see "re-dispatched
    # nothing" rather than a NoMethodError on a missing key.
    { reaped_pending: 0, reaped_running: failed, reaped_unrunnable: cancelled }
  end

  private

  # LANE 1 IS RETIRED (campaign 01a0790b increment 3). It re-issued a
  # SystemExecuteTaskJob for a stuck pending task, skipping agent-delegated
  # commands because "the dispatcher leaves them pending on purpose, so the job
  # would run, decline, and change nothing".
  #
  # That is now true of EVERY command. The server dispatch arm the job called
  # (worker_api/tasks/:id/execute -> ExecutionDispatcher) is deleted, the job
  # itself is deleted, and the janitor listing no longer carries the
  # `agent_delegated` flag the skip read — because it would be a constant true.
  # Re-dispatch is not a thing the platform does any more: the agent polls for
  # its own work.
  #
  # A stuck pending row is still reaped, by lane 3 (#reap_unrunnable), which is
  # what the retired lane's own comment already named as the closer for
  # agent-delegated rows.

  # Lane 2 — running tasks whose holding worker died. We cannot ping the
  # specific holder, so this is a time-since-STARTED heuristic; the server
  # transitions it to failed with the cause recorded.
  def reap_stuck_running
    tasks = janitor_tasks(status: %w[running])

    failed = 0
    tasks.each do |task|
      next unless stuck?(task["started_at"], STUCK_RUNNING_THRESHOLD)

      log_warn(
        "[SystemReaper] Failing stuck running task",
        task_id: task["id"], command: task["command"], started_at: task["started_at"]
      )
      next unless reap!(task, "execution_lost: stuck running > #{STUCK_RUNNING_THRESHOLD / 60} min")

      failed += 1
    end

    failed
  rescue BackendApiClient::ApiError => e
    log_error("[SystemReaper] Failed to reap stuck running tasks", e)
    0
  end

  # Lane 3 — the terminal policy, and since increment 3 the ONLY closer for a
  # pending row. A pending/scheduled task older than UNRUNNABLE_THRESHOLD is
  # closed because nothing will ever move it: its agent is gone, or the row
  # names an operable no agent polls for (delivery is
  # NodeApi::StatusController#pending_tasks -> current_instance.tasks, so a row
  # against a Node or a Provider* is offered to nothing). Without this lane the
  # queue only ever grows.
  #
  # The clause "or ~48 hourly re-enqueues have already failed to claim it" was
  # removed with lane 1: there are no re-enqueues, and there never were any that
  # reached a task — the job they fired POSTed to an endpoint that 404'd for
  # every id.
  def reap_unrunnable
    tasks = janitor_tasks(
      status: %w[pending scheduled],
      older_than_seconds: UNRUNNABLE_THRESHOLD
    )

    cancelled = 0
    tasks.each do |task|
      log_warn(
        "[SystemReaper] Cancelling unrunnable task",
        task_id: task["id"], command: task["command"],
        created_at: task["created_at"]
      )
      next unless reap!(
        task,
        "unrunnable: still #{task['status']} after #{UNRUNNABLE_THRESHOLD / 3600} h"
      )

      cancelled += 1
    end

    cancelled
  rescue BackendApiClient::ApiError => e
    log_error("[SystemReaper] Failed to reap unrunnable tasks", e)
    0
  end

  # POSTs the reap intent. The SERVER chooses fail-vs-cancel from the row's own
  # state and reports which in `transition`; a row that reached a terminal state
  # in the meantime comes back reaped:false, which is counted as not-reaped
  # rather than treated as an error.
  def reap!(task, reason)
    response = api_client.post(
      "#{JANITOR_TASKS_PATH}/#{task['id']}/reap",
      { reason: reason }
    )
    reaped = response.dig("data", "reaped")
    unless reaped
      log_info(
        "[SystemReaper] Task no longer reapable",
        task_id: task["id"], detail: response.dig("data", "detail")
      )
    end
    reaped
  rescue BackendApiClient::ApiError => e
    log_error("[SystemReaper] Failed to reap task #{task['id']}", e)
    false
  end

  def janitor_tasks(status:, older_than_seconds: nil)
    query = { status: status, per_page: 200 }
    query[:older_than_seconds] = older_than_seconds if older_than_seconds
    response = api_client.get(JANITOR_TASKS_PATH, query)
    response.dig("data", "tasks") || []
  end

  def stuck?(timestamp_string, threshold_seconds)
    return false if timestamp_string.blank?
    timestamp = Time.parse(timestamp_string.to_s)
    (Time.current - timestamp) >= threshold_seconds
  rescue ArgumentError
    false
  end
end
