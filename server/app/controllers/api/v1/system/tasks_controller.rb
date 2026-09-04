# frozen_string_literal: true

module Api
  module V1
    module System
      class TasksController < BaseController
        before_action :set_task, only: [ :show, :cancel, :abort ]

        # GET /api/v1/system/tasks
        def index
          require_permission("system.infra_tasks.read")

          tasks = current_account.system_tasks
          tasks = apply_filters(tasks)
          tasks = paginate(tasks.includes(:operable, :initiated_by).recent)

          render_success(
            tasks: tasks.map { |t| ::System::TaskSerializer.new(t).as_json },
            meta: pagination_meta
          )
        end

        # GET /api/v1/system/tasks/:id
        def show
          require_permission("system.infra_tasks.read")
          render_success(task: ::System::TaskSerializer.new(@task).as_json)
        end

        # POST /api/v1/system/tasks
        # Idempotent: caller may supply `idempotency_key` in the params body;
        # a duplicate POST with the same key+account returns the existing
        # task instead of creating a second one. This protects against
        # flaky-network retry double-provisioning.
        #
        # Mutating commands flow through Ai::AutonomyGate first — see
        # `System::Governance::PolicyDeclarations::MANUAL_OPERATION_DEFAULT_VERBS`
        # for the per-command policy defaults (written by PolicyReconciler, the
        # single writer, since IMP-28cccf7cee28). If the gate returns `:pending` the operator gets a 202
        # with the approval_request_id and can approve from the notification
        # center; the task is created when the chain completes.
        def create
          require_permission("system.infra_tasks.create")

          if (key = task_params[:idempotency_key]).present?
            existing = current_account.system_tasks.find_by(idempotency_key: key)
            if existing
              return render_success(
                task: ::System::TaskSerializer.new(existing).as_json,
                status: :ok
              )
            end
          end

          attrs = task_params.to_h.merge(initiated_by_id: current_user.id)
          gate_result = ::Ai::AutonomyGate.evaluate(
            action_category: "system.task.#{attrs[:command]}",
            executor_class: "System::Executors::ExecuteTask",
            params: { task_attributes: attrs },
            account: current_account,
            requested_by: current_user,
            # Anchor the operable as the operation's source. Without the pair,
            # Ai::DeferredOperation#assert_source_within_account! has nothing to
            # re-check and skips entirely, leaving the executor's own
            # resolve_scoped as the single defense. The two cover different
            # moments — the source pair is re-anchored immediately before the
            # replay, the executor anchors what it actually dereferences.
            source_type: attrs[:operable_type].presence,
            source_id: attrs[:operable_id].presence,
            # ONE label for both surfaces of this approval — see
            # System::Executors::ExecuteTask.gate_description. This used to
            # build its own raw pair, which disagreed with the card's impact
            # line for the very same operation (IMP-1dd3ed2b5353).
            description: ::System::Executors::ExecuteTask.gate_description(attrs)
          )

          case gate_result.decision
          when :proceed
            data = gate_result.result&.dig(:data) || {}
            task = current_account.system_tasks.find_by(id: data[:task_id])
            if task
              render_success(task: ::System::TaskSerializer.new(task).as_json, status: :created)
            else
              render_error("Task creation succeeded but row not found", status: :internal_server_error)
            end
          when :pending
            render_pending_approval(gate_result.deferred_operation,
                                    message: "Approval required for #{attrs[:command]}")
          when :blocked
            render_error(gate_result.error || "Action blocked by policy",
                         status: :unprocessable_content)
          end
        end

        # POST /api/v1/system/tasks/:id/cancel
        # start/complete/fail stay worker-only: those transitions belong to
        # the worker dispatch chain, where the AASM state machine is the
        # single source of truth, and allowing operators to forge them would
        # corrupt the audit trail. Cancel stays public because cancelling a
        # pending/scheduled task is a legitimate user action.
        def cancel
          require_permission("system.infra_tasks.control")
          transition_or_error(:cancel, params[:reason])
        end

        # POST /api/v1/system/tasks/:id/abort
        # IMP-8153d1952ff8 — a wedged provision/build/ssh task shows :running
        # with no operator recourse short of the hourly reaper's 60-min
        # STUCK_RUNNING threshold. The `abort` AASM event (legal from
        # :running) already existed for the worker dispatch chain; expose it
        # here behind the same infra_tasks.control gate as cancel.
        def abort
          require_permission("system.infra_tasks.control")
          transition_or_error(:abort, params[:reason])
        end

        private

        # Run an AASM transition with the platform-standard "may? then bang"
        # pattern. Translates AASM's whiny invalid-transition into a 422
        # response with a clear message.
        def transition_or_error(event, *args)
          unless @task.public_send("may_#{event}?")
            return render_error(
              "Cannot #{event} task in #{@task.status} state",
              status: :unprocessable_content
            )
          end
          @task.public_send("#{event}!", *args)
          render_success(task: ::System::TaskSerializer.new(@task.reload).as_json)
        end

        def set_task
          @task = current_account.system_tasks.find(params[:id])
        end

        def task_params
          params.require(:task).permit(
            :command, :description, :scheduled_at, :exclusive,
            :operable_type, :operable_id, :idempotency_key, options: {}
          )
        end

        def apply_filters(tasks)
          tasks = tasks.by_status(params[:status]) if params[:status].present?
          tasks = tasks.by_command(params[:command]) if params[:command].present?
          tasks = tasks.active if params[:active] == "true"
          tasks = tasks.finished if params[:finished] == "true"
          tasks = tasks.exclusive if params[:exclusive] == "true"
          tasks
        end
      end
    end
  end
end
