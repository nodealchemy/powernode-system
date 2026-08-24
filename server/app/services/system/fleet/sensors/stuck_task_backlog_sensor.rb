# frozen_string_literal: true

# The OUTCOME oracle for the System task janitor.
#
# WHY THIS EXISTS — the failure it is built from
#
# SystemTaskReaperJob ran hourly for five weeks and reported
# `reap cycle complete, 0, 0` — success — every time. Its list query was scoped
# through `System::Node.where(worker: current_worker)`, and `node.worker_id` is
# NULL on every node that has ever existed, so the scope was the empty set. The
# job was healthy, its logs were green, its error rate was zero, and it was
# doing nothing. 33 tasks accumulated behind it, the oldest for five weeks.
#
# The reason nobody noticed is the whole point of this file:
#
#   AN EMPTY JANITOR AND A CLEAN FLEET PRODUCE THE SAME LOG LINE.
#
# Nothing could distinguish them, because every signal available was a
# SELF-REPORT by the mechanism under suspicion. A job that cannot see its
# subjects reports zero work; so does a job with genuinely nothing to do.
#
# WHAT THIS SENSES, AND WHY IT IS NOT ANOTHER SELF-REPORT
#
# This sensor never reads the reaper's status, logs, counters, or last-run
# time. It reads the PROPERTY the reaper exists to maintain: no System::Task
# stays non-terminal indefinitely. If a task is still pending/scheduled/running
# long past any threshold the reaper could reasonably hold, then the reaper is
# not doing its job — and this is true whatever the cause: an empty scope, a
# crashed worker, a disabled cron entry, a revoked permission, a seam that
# 404s, or a future regression nobody has thought of yet. The observable is the
# outcome, so it survives changes to the mechanism.
#
# This is deliberately the inverse of the usual instinct, which is to monitor
# the job. Monitoring the job would have reported five weeks of perfect health.
#
# WHY 72 HOURS, AND WHY IT IS NOT THE REAPER'S THRESHOLD
#
# The reaper closes unrunnable tasks at 48h (SystemTaskReaperJob::
# UNRUNNABLE_THRESHOLD, which lives in the WORKER app and is deliberately NOT
# imported here). Copying that constant across the app boundary would couple
# the alarm to the policy, so tuning the reaper would silently move the alarm
# with it — and a threshold that always agrees with the thing it audits cannot
# ever disagree with it.
#
# Instead this bound is INDEPENDENT and deliberately looser: 72h is 48h plus a
# full day, i.e. ~24 further hourly reap cycles. Anything still non-terminal
# then has survived every remedy the janitor has, so the conclusion "the
# janitor is not working" holds without this file knowing what the janitor's
# policy is. If someone raises the reaper's threshold above 72h the sensor
# starts complaining — correctly: it is asserting a platform-level bound on how
# long work may sit, which is a property the operator owns, not the job.
#
# NO APPLIER, BY DESIGN — and this must not be "fixed"
#
# There is no auto-remediation for "the janitor is inert". The failure modes
# are code and configuration: an empty scope, a broken seam, a stopped worker.
# Nothing the platform can dispatch repairs any of them, and a lane that
# pretends otherwise is the exact defect class this file exists to expose.
# The category is therefore listed in
# RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES, and the policy is
# notify_and_proceed — "proceed" meaning "reach an operator".
#
# DO NOT collapse this to system.observation: the fleet seed maps that to
# auto_approve, which files the signal for a dashboard and reaches NO operator.
# That would make this sensor itself inert, which would be a genuinely funny
# way to lose another five weeks.
module System
  module Fleet
    module Sensors
      class StuckTaskBacklogSensor < BaseSensor
        # An independent upper bound on how long any task may remain
        # non-terminal. See the class comment for why this is NOT the reaper's
        # own threshold. Overridable so an operator can tighten it without a
        # deploy; never read from the worker's constant.
        DEFAULT_STUCK_AFTER_SECONDS = 72 * 3600 # 72 hours

        # Escalation. A handful of aged rows is a janitor that missed; dozens,
        # or rows weeks old, is a janitor that is structurally not running —
        # which is what the original incident looked like.
        HIGH_AFTER_SECONDS     = 7  * 24 * 3600
        CRITICAL_AFTER_SECONDS = 14 * 24 * 3600
        CRITICAL_COUNT         = 20

        # Itemise a bounded sample. The payload reaches an ApprovalRequest, and
        # a 30-row backlog must not render an unreadable card — the COUNT is
        # the signal, the sample is for orientation.
        SAMPLE_LIMIT = 5

        NON_TERMINAL = %w[pending scheduled running].freeze

        def sense
          cutoff = Time.current - stuck_after_seconds
          rows = stuck_rows(cutoff)
          return [] if rows.empty?

          oldest_age = (Time.current - rows.map { |r| reference_time(r) }.min).to_i

          [
            signal(
              kind: "system.task_backlog_stuck",
              severity: severity_for(count: rows.size, oldest_age: oldest_age),
              payload: build_payload(rows, oldest_age),
              # STABLE across ticks, deliberately. The backlog's size changes
              # every hour; a fingerprint that moved with it would mint a fresh
              # signal each tick and bury the operator, and the DecisionEngine
              # could never dedup a standing condition.
              fingerprint: "task_backlog_stuck:#{account.id}"
            )
          ]
        rescue StandardError => e
          Rails.logger.warn("[StuckTaskBacklogSensor] failed: #{e.class}: #{e.message}")
          []
        end

        private

        def stuck_after_seconds
          ENV.fetch("SYSTEM_TASK_BACKLOG_STUCK_SECONDS", DEFAULT_STUCK_AFTER_SECONDS).to_i
        end

        # A :running task is measured from when it STARTED, not when it was
        # created — a task can legitimately sit queued a while before a worker
        # claims it, and charging that wait against the running clock would
        # flag healthy work. Falls back to created_at when started_at is NULL
        # (a row that claims to be running without a start time is itself
        # broken, and must not become invisible by having no clock).
        def reference_time(task)
          return task.created_at unless task.status == "running"

          task.started_at || task.created_at
        end

        def stuck_rows(cutoff)
          ::System::Task
            .where(account_id: account.id, status: NON_TERMINAL)
            .where(
              "(status = 'running' AND COALESCE(started_at, created_at) < :c) OR " \
              "(status <> 'running' AND created_at < :c)",
              c: cutoff
            )
            .order(created_at: :asc)
            .limit(500)
            .to_a
        end

        def severity_for(count:, oldest_age:)
          return :critical if oldest_age >= CRITICAL_AFTER_SECONDS || count >= CRITICAL_COUNT
          return :high     if oldest_age >= HIGH_AFTER_SECONDS

          :medium
        end

        def build_payload(rows, oldest_age)
          {
            "stuck_count" => rows.size,
            "oldest_age_hours" => (oldest_age / 3600.0).round(1),
            "threshold_hours" => (stuck_after_seconds / 3600.0).round(1),
            "by_status" => rows.group_by(&:status).transform_values(&:size),
            "by_command" => rows.group_by(&:command).transform_values(&:size),
            "sample" => rows.first(SAMPLE_LIMIT).map do |t|
              {
                "task_id" => t.id,
                "command" => t.command,
                "status" => t.status,
                "age_hours" => ((Time.current - reference_time(t)) / 3600.0).round(1)
              }
            end,
            # Names the suspicion without asserting a cause. The reaper is the
            # mechanism responsible for this property; it is not necessarily
            # the thing that is broken.
            "expected_owner" => "SystemTaskReaperJob (hourly)"
          }
        end
      end
    end
  end
end
