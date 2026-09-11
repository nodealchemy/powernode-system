# frozen_string_literal: true

module System
  module Status
    module Contributors
      # The task pickup pipeline, one component per account (campaign
      # 01a08c9b B5, checklist row 22).
      #
      # ── WHAT IT READS ───────────────────────────────────────────────────
      # System::Task rows ARE the dispatch pipeline. A producer writes a
      # pending row, and the instance's agent is offered it on every status
      # report (NodeApi::StatusController#pending_tasks) and stamps started_at
      # when it starts it. Pickup latency is started_at minus the moment the
      # row fell due: created_at, or scheduled_at when that is later.
      #
      # This used to read the system.dispatch.* Rails.cache counters. Nothing
      # has written those since the server dispatch spine was retired
      # (2026-09-07), so it could only ever read ok (B5 review H1). The rows
      # are what the pipeline writes today.
      #
      # ── TWO CONDITIONS ──────────────────────────────────────────────────
      # PickupLatency: p50 and p95 over the tasks picked up within one status
      # sweep interval (platform.status.sweep_interval_seconds), the window
      # this component is re-read on. No latency threshold is ruled, so a
      # measured latency is reported, not judged. None picked up is a
      # MEASURED quiet window: ok, a count of 0, and the percentiles nil,
      # never 0.
      #
      # NoStuckPending: a waiting task (pending, or scheduled) that fell due
      # longer ago than the account's silent threshold (InstanceStatusSensor
      # silent_threshold_seconds, the rule that calls an instance silent). An
      # agent reporting inside that window is offered a pending task on every
      # report, and the worker is offered pending and scheduled rows once they
      # fall due (Internal::System::AccountsController#pending_tasks), so a task
      # older than it was not picked up by a live consumer. Any such task
      # degrades the component, and the oldest are named. A task scheduled for
      # later is not stuck before it falls due.
      #
      # A failed read is not_measured with reason QueryFailed, never ok.
      class DispatchLatencyContributor < ::Platform::Status::Contributor
        include ::System::Status::ConditionHelpers

        KIND = "dispatch_latency"
        REF  = "dispatch_pipeline"

        TASKS         = ::System::Task
        SWEEP         = ::Platform::Status::SweepService
        SILENT_SENSOR = ::System::Fleet::Sensors::InstanceStatusSensor
        SILENT_KEY    = "silent_threshold_seconds"

        PICKUP = "PickupLatency"
        STUCK  = "NoStuckPending"

        # When a row fell due, and how long it then waited to start.
        DUE_AT  = "GREATEST(system_tasks.created_at, COALESCE(system_tasks.scheduled_at, system_tasks.created_at))"
        LATENCY = "GREATEST(0, EXTRACT(EPOCH FROM (system_tasks.started_at - #{DUE_AT})))::double precision".freeze

        # The statuses a consumer is offered (the worker's pending_tasks set).
        WAITING = %w[pending scheduled].freeze

        # How many stuck tasks the evidence names. A display limit, not a threshold.
        STUCK_NAMED = 5

        Pipeline = Struct.new(:account, keyword_init: true)

        def kind = KIND

        def account_scoped? = true

        # Design §5.4: fleet kinds keep their own lane's escalation.
        def escalates? = false

        def each_component(account)
          return if account.blank?

          yield Pipeline.new(account: account)
        end

        def ref_for(_record) = REF

        def display_name_for(_record) = "Dispatch pipeline"

        def presentation
          { "icon" => "Timer", "label" => "Dispatch pipeline", "group_order" => 120 }
        end

        def conditions_for(record)
          now = Time.current
          account = record.account
          window = SWEEP.sweep_interval_seconds
          threshold = silent_threshold(account)
          [ pickup_condition(pickup_stats(account, window, now), window, now),
            stuck_condition(stuck_tasks(account, threshold, now), threshold, now) ]
        rescue ActiveRecord::ActiveRecordError => e
          [ query_failed(PICKUP, e, now), query_failed(STUCK, e, now) ]
        end

        private

        def tasks(account)
          TASKS.where(account_id: account.id)
        end

        def silent_threshold(account)
          SILENT_SENSOR.resolved_threshold(SILENT_KEY, account: account).to_i
        end

        def pickup_stats(account, window, now)
          count, p50, p95 = tasks(account).where(started_at: (now - window.seconds)..now).pick(
            Arel.sql("COUNT(*)"),
            Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY #{LATENCY})"),
            Arel.sql("percentile_cont(0.95) WITHIN GROUP (ORDER BY #{LATENCY})")
          )
          { count: count.to_i, p50: p50&.to_f&.round(3), p95: p95&.to_f&.round(3) }
        end

        def stuck_tasks(account, threshold, now)
          scope = tasks(account).where(status: WAITING).where("#{DUE_AT} <= ?", now - threshold.seconds)
          named = scope.order(Arel.sql("#{DUE_AT} ASC")).limit(STUCK_NAMED)
                       .pluck(:id, :command, :operable_type, :operable_id, Arel.sql(DUE_AT))
          { count: scope.count, named: named }
        end

        def pickup_condition(stats, window, now)
          evidence = {
            "source" => "system_tasks.started_at minus created_at (or a later scheduled_at), account-scoped",
            "window_seconds" => window,
            "window_source" => SWEEP::SWEEP_INTERVAL_SETTING,
            "picked_up" => stats[:count],
            "p50_seconds" => stats[:p50],
            "p95_seconds" => stats[:p95]
          }
          if stats[:count].zero?
            CONDITION.build(type: PICKUP, status: true, reason: "QuietWindow",
                            message: "no task was picked up in the last #{window}s",
                            evidence: evidence, now: now)
          else
            CONDITION.build(type: PICKUP, status: true, reason: "Measured",
                            message: "p50 #{stats[:p50]}s, p95 #{stats[:p95]}s over #{stats[:count]} task(s) " \
                                     "picked up in the last #{window}s",
                            evidence: evidence, now: now)
          end
        end

        def stuck_condition(stuck, threshold, now)
          evidence = {
            "source" => "system_tasks with status pending or scheduled, due longer ago than the threshold, account-scoped",
            "threshold_seconds" => threshold,
            "threshold_source" => "#{SILENT_SENSOR.name} #{SILENT_KEY}, resolved for this account",
            "stuck_count" => stuck[:count],
            "oldest" => stuck[:named].map do |id, command, operable_type, operable_id, due_at|
              { "id" => id, "command" => command, "operable_type" => operable_type,
                "operable_id" => operable_id, "due_at" => due_at&.iso8601 }
            end
          }
          if stuck[:count].zero?
            CONDITION.build(type: STUCK, status: true, reason: "NoneStuck", evidence: evidence, now: now)
          else
            CONDITION.build(
              type: STUCK, status: false, reason: "PendingNotPickedUp", severity: CONDITION::SEVERITY_DEGRADED,
              message: "#{stuck[:count]} task(s) pending longer than the silent threshold (#{threshold}s)",
              evidence: evidence, now: now
            )
          end
        end

        def query_failed(type, error, now)
          CONDITION.build(
            type: type,
            status: CONDITION::UNKNOWN,
            reason: "QueryFailed",
            message: "the system_tasks read failed (#{error.class}), so nothing was measured",
            evidence: { "source" => "system_tasks, account-scoped", "error" => "#{error.class}: #{error.message}" },
            now: now
          )
        end
      end
    end
  end
end
