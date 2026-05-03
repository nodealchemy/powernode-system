# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Operation tracking and management for infrastructure workers
        # Handles operation lifecycle: create, start, progress, complete, fail
        class TasksController < BaseController
          before_action :set_operation, only: [ :show, :start, :progress, :complete, :fail, :add_event, :execute ]

          # GET /api/v1/system/worker_api/operations
          # List operations for resources managed by this worker
          def index
            authorize_worker_permission!("system.tasks.read")

            operations = worker_operations
            operations = apply_filters(operations)
            operations = paginate(operations.order(created_at: :desc))

            render_success(
              tasks: operations.map { |o| serialize_task(o) },
              meta: pagination_meta
            )
          end

          # GET /api/v1/system/worker_api/operations/pending
          # Get pending operations that need to be processed
          def pending
            authorize_worker_permission!("system.tasks.read")

            operations = worker_operations.where(status: "pending")
                                          .order(created_at: :asc)
                                          .limit(params[:limit] || 10)

            render_success(
              tasks: operations.map { |o| serialize_task(o) },
              count: operations.size
            )
          end

          # GET /api/v1/system/worker_api/operations/:id
          def show
            authorize_worker_permission!("system.tasks.read")
            render_success(task: serialize_operation_full(@operation))
          end

          # POST /api/v1/system/worker_api/operations
          # Create new operation
          def create
            authorize_worker_permission!("system.tasks.create")

            operable = find_operable
            return unless operable

            operation = operable.tasks.build(operation_params)
            operation.account = operable.respond_to?(:account) ? operable.account : worker_account

            if operation.save
              render_success(task: serialize_task(operation), status: :created)
            else
              render_validation_error(operation)
            end
          end

          # POST /api/v1/system/worker_api/operations/:id/start
          # Mark operation as started
          def start
            authorize_worker_permission!("system.tasks.manage")

            if @operation.pending?
              @operation.update!(
                status: "running",
                started_at: Time.current,
                progress: 0
              )
              add_operation_event("started", "Operation started by worker")

              render_success(task: serialize_task(@operation))
            else
              render_error("Operation cannot be started from #{@operation.status} state")
            end
          end

          # PUT /api/v1/system/worker_api/operations/:id/progress
          # Update operation progress
          def progress
            authorize_worker_permission!("system.tasks.manage")

            unless @operation.running?
              return render_error("Can only update progress of running operations")
            end

            progress_value = params[:progress].to_i
            message = params[:message]

            @operation.update!(progress: progress_value)
            add_operation_event("progress", message) if message.present?

            render_success(
              task: serialize_task(@operation),
              progress: progress_value
            )
          end

          # POST /api/v1/system/worker_api/operations/:id/complete
          # Mark operation as completed
          def complete
            authorize_worker_permission!("system.tasks.manage")

            unless @operation.running?
              return render_error("Only running operations can be completed")
            end

            result = params[:result] || {}

            @operation.update!(
              status: "complete",
              progress: 100,
              completed_at: Time.current,
              result: result
            )
            add_operation_event("completed", params[:message] || "Operation completed successfully")

            render_success(task: serialize_task(@operation))
          end

          # POST /api/v1/system/worker_api/operations/:id/fail
          # Mark operation as failed
          def fail
            authorize_worker_permission!("system.tasks.manage")

            unless @operation.pending? || @operation.running?
              return render_error("Operation cannot be marked as failed from #{@operation.status} state")
            end

            error_message = params[:error_message] || "Operation failed"

            @operation.update!(
              status: "failed",
              completed_at: Time.current,
              error_message: error_message
            )
            add_operation_event("failed", error_message)

            render_success(task: serialize_task(@operation))
          end

          # POST /api/v1/system/worker_api/operations/:id/execute
          #
          # Atomically claims the operation, runs the matching runtime service,
          # and transitions to complete/failed before responding. Holds the HTTP
          # connection for the duration of the operation (typically <2 min for
          # provisioning).
          #
          # Triggered by SystemExecuteTaskJob in the worker, which itself
          # is enqueued by an after_commit callback on Operation creation. The
          # full dispatch chain has zero polling.
          def execute
            authorize_worker_permission!("system.tasks.execute")

            outcome = ::System::ExecutionDispatcher.run(@operation, worker: current_worker)

            if outcome.claimed
              render_success(
                task: serialize_operation_full(@operation.reload),
                runtime_result: outcome.result.to_h
              )
            else
              # Already-claimed or non-claimable operation — respond 409 Conflict
              # so the worker logs and exits without retrying.
              render_error(outcome.result.error, status: outcome.status_code)
            end
          end

          # POST /api/v1/system/worker_api/operations/:id/events
          # Add event to operation log
          def add_event
            authorize_worker_permission!("system.tasks.manage")

            event_type = params[:event_type] || "info"
            message = params[:message]

            return render_error("Message is required") if message.blank?

            add_operation_event(event_type, message)

            render_success(
              task: serialize_task(@operation),
              event_added: true
            )
          end

          private

          def set_operation
            @operation = worker_operations.find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("Operation")
          end

          def worker_operations
            # Get operations for nodes managed by this worker
            node_ids = ::System::Node.where(worker: current_worker).pluck(:id)
            instance_ids = ::System::NodeInstance.where(node_id: node_ids).pluck(:id)

            ::System::Task.where(
              "(operable_type = 'System::Node' AND operable_id IN (?)) OR " \
              "(operable_type = 'System::NodeInstance' AND operable_id IN (?))",
              node_ids,
              instance_ids
            )
          end

          def find_operable
            operable_type = params[:operable_type]
            operable_id = params[:operable_id]

            case operable_type
            when "System::Node", "node"
              ::System::Node.where(worker: current_worker).find(operable_id)
            when "System::NodeInstance", "instance"
              ::System::NodeInstance
                .joins(:node)
                .where(system_nodes: { worker_id: current_worker.id })
                .find(operable_id)
            else
              render_error("Invalid operable_type: #{operable_type}")
              nil
            end
          rescue ActiveRecord::RecordNotFound
            render_record_not_found(operable_type)
            nil
          end

          def operation_params
            params.require(:operation).permit(
              :command, :status, :progress,
              options: {}
            )
          end

          def apply_filters(scope)
            scope = scope.where(status: params[:status]) if params[:status].present?
            scope = scope.where(command: params[:command]) if params[:command].present?
            scope = scope.where("status IN (?)", %w[pending running]) if params[:active] == "true"
            scope = scope.where("status IN (?)", %w[complete failed]) if params[:finished] == "true"
            scope
          end

          def add_operation_event(event_type, message)
            events = @operation.events || []
            events << {
              type: event_type,
              message: message,
              timestamp: Time.current.iso8601,
              worker_id: current_worker.id
            }
            @operation.update!(events: events)
          end

          # Worker-facing serialization defers to the operator-facing
          # TaskSerializer for shape parity. Workers and operators see the
          # same field names for the same domain object — anything else
          # invites client-side branching ("if response came from worker_api,
          # the field is `operable_type`; if operator, it's the same").
          # Centralizing in one serializer means contract changes happen
          # once.
          def serialize_task(operation)
            ::System::TaskSerializer.new(operation).as_json
          end

          # Full serialization additionally includes the runtime result. The
          # base TaskSerializer already includes events, options, duration,
          # so we only add `result` here.
          def serialize_operation_full(operation)
            serialize_task(operation).merge(result: operation.result)
          end
        end
      end
    end
  end
end
