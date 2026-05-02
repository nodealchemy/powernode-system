# frozen_string_literal: true

module Api
  module V1
    module System
      class TasksController < BaseController
        before_action :set_task, only: [:show, :cancel]

        # GET /api/v1/system/tasks
        def index
          require_permission('system.infra_tasks.read')

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
          require_permission('system.infra_tasks.read')
          render_success(task: ::System::TaskSerializer.new(@task).as_json)
        end

        # POST /api/v1/system/tasks
        # Idempotent: caller may supply `idempotency_key` in the params body;
        # a duplicate POST with the same key+account returns the existing
        # task instead of creating a second one. This protects against
        # flaky-network retry double-provisioning.
        def create
          require_permission('system.infra_tasks.create')

          if (key = task_params[:idempotency_key]).present?
            existing = current_account.system_tasks.find_by(idempotency_key: key)
            if existing
              return render_success(
                task: ::System::TaskSerializer.new(existing).as_json,
                status: :ok
              )
            end
          end

          task = current_account.system_tasks.build(task_params)
          task.initiated_by = current_user

          if task.save
            render_success(task: ::System::TaskSerializer.new(task).as_json, status: :created)
          else
            render_validation_error(task)
          end
        end

        # POST /api/v1/system/tasks/:id/cancel
        # The other state mutations (start/complete/fail/abort) are
        # deliberately NOT exposed publicly: those transitions belong to the
        # worker dispatch chain, where the AASM state machine is the single
        # source of truth. Allowing operators to forge them would corrupt the
        # audit trail. Cancel stays public because cancelling a pending task
        # is a legitimate user action.
        def cancel
          require_permission('system.infra_tasks.control')
          transition_or_error(:cancel, params[:reason])
        end

        private

        # Run an AASM transition with the platform-standard "may? then bang"
        # pattern. Translates AASM's whiny invalid-transition into a 422
        # response with a clear message.
        def transition_or_error(event, *args)
          unless @task.public_send("may_#{event}?")
            return render_error(
              "Cannot #{event} task in #{@task.status} state",
              status: :unprocessable_entity
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
          tasks = tasks.active if params[:active] == 'true'
          tasks = tasks.finished if params[:finished] == 'true'
          tasks = tasks.exclusive if params[:exclusive] == 'true'
          tasks
        end
      end
    end
  end
end
