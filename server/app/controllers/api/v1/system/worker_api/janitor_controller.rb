# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Account-scoped janitor seam for SystemTaskReaperJob.
        #
        # WHY THIS EXISTS AS A SEPARATE CONTROLLER
        #
        # The reaper used TasksController, whose every action is scoped through
        # `worker_operations`:
        #
        #     node_ids = ::System::Node.where(worker: current_worker).pluck(:id)
        #
        # `node.worker_id` is NULL on every node that has ever existed (157/157
        # measured on live ops-hub 2026-08-24) and nothing assigns it — it appears
        # only as an optional inbound param. So that scope resolves to the EMPTY
        # SET, and the reaper's list call returned `[]` every hour: it logged
        # "0 reaped, success" for five weeks while the backlog grew. An hourly
        # janitor that reports success while seeing nothing is indistinguishable
        # from a clean fleet, which is why nobody noticed.
        #
        # The recorded decision (knowledge 01a031f2, "the node agent is the
        # authoritative dispatch spine") explicitly REJECTS the tempting minimal
        # fix of populating `node.worker_id` to make that scope true: it would
        # revive a dispatch chain that has never run in production and race the
        # agent on the four colliding command names, on a live self-hosted
        # control plane. The reaper is re-homed instead. TasksController is left
        # untouched — it is vestigial and retires under step 3 of that decision.
        #
        # THE TENANCY ANCHOR IS THE PRINCIPAL, NEVER A PARAMETER
        #
        # Scoping is `current_worker.account_id` — the COLUMN on the authenticated
        # Worker, mirroring Api::V1::Internal::WorkerTenancy in core. Note this
        # deliberately does NOT use BaseController#worker_account, which falls
        # back to `Account.find(params[:account_id])`: that is a caller-supplied
        # widener, and a janitor that can terminally close tasks must not have
        # one. A nil principal yields `where(account_id: nil)`, which matches no
        # rows — denied, not granted, since system_tasks.account_id is NOT NULL.
        #
        # WHY THE TERMINAL TRANSITION LIVES HERE AND NOT ON THE WORKER
        #
        # System::Task's AASM table admits `fail` only from :running, and
        # :pending/:scheduled reach a terminal state through `cancel`. Which one
        # applies is a property of the row at the moment it is read, under the
        # same lock as the write. Having the worker pick would make it re-derive
        # the server's state machine from a serialized snapshot and race it. So
        # the worker declares INTENT ("this one is unrunnable, reap it") and the
        # server performs whichever transition is legal — and REPORTS which, so
        # the outcome is declared rather than inferred by the caller.
        class JanitorController < BaseController
          # Ordered OLDEST-FIRST, deliberately. TasksController#index orders
          # `created_at: :desc` and paginates, so with more stuck rows than one
          # page the MOST stuck are the ones that fall off the end — exactly
          # backwards for a reaper. The oldest row in the current backlog dates
          # to 2026-07-19; it must be on page one.
          MAX_PER_PAGE = 200

          # GET /api/v1/system/worker_api/janitor/tasks
          #
          # Params:
          #   status[]            — statuses to consider (default: the active set)
          #   older_than_seconds  — only rows whose created_at is at least this
          #                         old. Filtering server-side keeps the page
          #                         budget spent on rows that are actually stuck.
          #   per_page            — capped at MAX_PER_PAGE
          def tasks
            authorize_worker_permission!("system.tasks.read")

            scope = janitor_scope.where(status: requested_statuses)

            if (age = params[:older_than_seconds].presence)
              scope = scope.where(created_at: ..(Time.current - age.to_i.seconds))
            end

            rows = scope.order(created_at: :asc).limit(page_size)

            render_success(
              tasks: rows.map { |t| serialize_janitor_task(t) },
              count: rows.size
            )
          end

          # POST /api/v1/system/worker_api/janitor/tasks/:id/reap
          #
          # Terminally closes ONE task the reaper has judged unrunnable. The
          # legal transition is chosen from the row's own state:
          #
          #   :running              -> fail    (it started and its holder died)
          #   :pending / :scheduled -> cancel  (it never started; "failed" would
          #                                     assert an execution that never
          #                                     happened)
          #
          # Idempotent by design: a row that reached a terminal state between the
          # list call and this one returns 200 with reaped: false and the state
          # it settled in, rather than 409. The reaper runs hourly against a
          # snapshot it fetched seconds ago; a benign lost race must not surface
          # as an error it would log and retry.
          def reap
            authorize_worker_permission!("system.tasks.manage")

            task = janitor_scope.find(params[:id])
            reason = params[:reason].presence || "reaped by SystemTaskReaperJob"

            transition =
              if task.running?             then :fail
              elsif task.pending? || task.scheduled? then :cancel
              end

            if transition.nil?
              return render_success(
                task: serialize_janitor_task(task),
                reaped: false,
                transition: nil,
                detail: "already terminal (#{task.status})"
              )
            end

            task.public_send(:"#{transition}!", reason)

            render_success(
              task: serialize_janitor_task(task),
              reaped: true,
              transition: transition.to_s
            )
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("Task")
          rescue AASM::InvalidTransition
            # Lost the race between the state read and the transition. Same
            # reasoning as the terminal branch above: report, don't error.
            task.reload
            render_success(
              task: serialize_janitor_task(task),
              reaped: false,
              transition: nil,
              detail: "raced to #{task.status}"
            )
          end

          private

          # The tenancy anchor. See the class comment: the principal's own
          # account_id COLUMN, with no params fallback, failing closed on nil.
          def janitor_scope
            ::System::Task.where(account_id: current_worker&.account_id)
          end

          def requested_statuses
            requested = Array(params[:status]).map(&:to_s).select(&:present?)
            allowed = requested & %w[pending scheduled running]
            allowed.presence || %w[pending scheduled running]
          end

          def page_size
            requested = params[:per_page].to_i
            return MAX_PER_PAGE unless requested.positive?
            [ requested, MAX_PER_PAGE ].min
          end

          # Only the fields the reaper's policy actually reads. A janitor listing
          # is not a general task feed; keeping it narrow means this seam cannot
          # become a second, divergent read surface for task data.
          def serialize_janitor_task(task)
            {
              id: task.id,
              command: task.command,
              status: task.status,
              created_at: task.created_at&.iso8601,
              started_at: task.started_at&.iso8601,
              operable_type: task.operable_type,
              operable_id: task.operable_id,
              agent_delegated: ::System::ExecutionDispatcher.agent_delegated?(task.command, task.options)
            }
          end
        end
      end
    end
  end
end
