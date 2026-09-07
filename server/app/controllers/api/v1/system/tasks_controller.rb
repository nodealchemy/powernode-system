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

          # REFUSE AN UNINSERTABLE COMMAND BEFORE GATING, not after approval.
          #
          # This arm composes its category from CALLER-SUPPLIED free text and
          # its executor (ExecuteTask) ends in save!. Without this guard a
          # command the model refuses still resolves a policy — and for
          # `terminate` that policy is a seeded require_approval, because the
          # category outlives the command on purpose (PolicyDeclarations::
          # GATED_NON_COMMAND_OPERATIONS: both lifecycle surfaces still gate the
          # destroy there). So the request would PARK an approval request, an
          # operator would approve it, and only then would ExecuteTask#perform
          # raise RecordInvalid and mark the operation failed.
          #
          # An approval an operator can grant but the platform can never honour
          # is worse than a refusal, and it is the shape
          # spec/integration/gate_composed_task_categories_spec.rb exists to
          # keep out of the gate. 422 here, before any row or approval exists.
          unless ::System::Task::COMMANDS.include?(attrs[:command].to_s)
            return render_error(
              "Unsupported command: #{attrs[:command]}. This endpoint creates a System::Task, " \
              "and the platform executes only #{::System::Task::COMMANDS.size} commands. " \
              "To destroy an instance use DELETE /api/v1/system/nodes/:node_id/node_instances/:id " \
              "or the system_terminate_instance MCP verb, which route to " \
              "System::Executors::TerminateInstance.",
              status: :unprocessable_content
            )
          end

          # IMP-93d9f4a31627 — refuse an on-node reconcile aimed at an instance
          # whose agent will never pull it, BEFORE the gate. System::Executors
          # ::ExecuteTask carries the same check (it is the load-bearing one:
          # an approved operation replays through it with no controller in the
          # path), but a refusal that only happens there arrives as
          # "Gate evaluation failed: ..." after a DeferredOperation has already
          # been written and, under a require_approval policy, after an operator
          # has been asked to approve work that can never run. Same shape as the
          # restart-scope refusal: the operator gets the reason, and nothing is
          # recorded.
          if (refusal = undeliverable_on_node_refusal(attrs))
            return render_error(refusal, status: :unprocessable_content)
          end

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
              # DISCLOSURE, not a refusal. NodeInstance#dormant_agent_reason
              # covers the statuses that are live for capacity but are running
              # no agent yet (stopped / rebooting / provisioning): the task is
              # the right thing to queue and IS pulled when an agent starts, so
              # refusing would be wrong — but reporting a bare success is what
              # IMP-cdf18862a7c1's review caught on system_refresh_instance_
              # modules, where an operator resyncing a box powered down last
              # week was told nothing at all.
              payload = { task: ::System::TaskSerializer.new(task).as_json }
              # The key is present only when there is something to say. A
              # `"dormant_agent_warning": null` on every create — including the
              # start/stop/restart verbs, where it is unconditionally nil —
              # would be noise on a hot response, and a consumer that tests for
              # the key rather than its value would read it as a warning.
              if (warning = dormant_on_node_warning(attrs))
                payload[:dormant_agent_warning] = warning
              end
              render_success(**payload, status: :created)
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

        # The reason an on-node reconcile queued for this request's target would
        # never be pulled, or nil. Both this and #dormant_on_node_warning defer
        # the whole decision — which commands, which operable shapes, and the
        # Node fan-out — to System::Task, so this copy and the executor's cannot
        # answer differently.
        def undeliverable_on_node_refusal(attrs)
          ::System::Task.undeliverable_on_node_refusal(
            command: attrs[:command], operable: on_node_target(attrs)
          )
        end

        # The DISCLOSURE arm — see the render_success call in #create.
        def dormant_on_node_warning(attrs)
          ::System::Task.dormant_on_node_reason(
            command: attrs[:command], operable: on_node_target(attrs)
          )
        end

        # The record an on-node reconcile in this request would target, or nil.
        #
        # Nil for a target this account cannot see, DELIBERATELY: the not-found
        # case belongs to ExecuteTask#resolve_operable, whose own comment
        # explains why an id that exists elsewhere and an id that exists nowhere
        # must be indistinguishable. Refusing differently here would rebuild the
        # existence oracle that method exists to collapse — and the executor
        # still refuses, so nothing is let through, only reported differently.
        #
        # The allowlist is System::Task's own — NOT a second copy. A local list
        # is how the two arms diverge: the seam decides which operable shapes it
        # can answer about, so a shape added there and not here would be refused
        # by the executor and waved through by this pre-check, which is exactly
        # the disagreement sharing the seam exists to prevent.
        #
        # It gates the constantize rather than following it, for the reason
        # ExecuteTask#resolve_operable gives: constantizing a caller-supplied
        # string to reach a validation is itself the thing to avoid.
        def on_node_target(attrs)
          return nil unless ::System::Task::ON_NODE_RECONCILE_COMMANDS.include?(attrs[:command].to_s)
          return nil unless ::System::Task::ON_NODE_LIVENESS_OPERABLE_TYPES.include?(attrs[:operable_type])

          attrs[:operable_type].constantize
                               .find_by(id: attrs[:operable_id], account_id: current_account.id)
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
