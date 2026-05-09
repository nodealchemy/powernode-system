# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Status reporting endpoint for node instances
        # Allows instances to report their status and receive commands
        class StatusController < BaseController
          # GET /api/v1/system/node_api/status
          # Get current instance status
          def show
            render_success(
              instance: serialize_instance_status,
              node: serialize_node_status,
              pending_tasks: pending_operations_count
            )
          end

          # POST /api/v1/system/node_api/status/report
          # Report instance status update
          def report
            status = params[:status]
            metrics = params[:metrics] || {}

            # Validate status
            unless ::System::NodeInstance::STATUSES.include?(status)
              return render_error("Invalid status: #{status}")
            end

            # Update instance status
            current_instance.update!(
              status: status,
              config: current_instance.config.merge(
                "last_report" => Time.current.iso8601,
                "metrics" => metrics
              )
            )

            # Check for pending operations
            pending = pending_tasks

            render_success(
              status_updated: true,
              current_status: current_instance.status,
              pending_tasks: pending.map { |o| serialize_task(o) }
            )
          end

          # POST /api/v1/system/node_api/status/heartbeat
          #
          # Body (from powernode-agent's runtime.HeartbeatPayload):
          #   boot_id, agent_version, architecture, uptime_seconds,
          #   module_digests (hash of module_id → oci_digest), mount_state,
          #   load_average, memory_free_kb
          #
          # Persists into the NodeInstance's M0.M runtime telemetry columns
          # (last_heartbeat_at, agent_version, boot_id, running_module_digests,
          # architecture) via the model's record_heartbeat! method.
          def heartbeat
            digests = params[:module_digests]
            digests = digests.to_unsafe_h if digests.respond_to?(:to_unsafe_h)
            current_instance.record_heartbeat!(
              agent_version:  params[:agent_version].presence || "unknown",
              boot_id:        params[:boot_id].presence       || "unknown",
              module_digests: digests || {},
              architecture:   params[:architecture]
            )

            # Transition pending → running on first heartbeat post-enrollment.
            current_instance.mark_running! if current_instance.may_mark_running?

            render_success(
              acknowledged:      true,
              server_time:       Time.current.iso8601,
              next_poll_seconds: 30
            )
          end

          # GET /api/v1/system/node_api/status/operations
          # Get pending operations for this instance
          def tasks
            operations = pending_tasks.order(created_at: :asc)

            render_success(
              tasks: operations.map { |o| serialize_operation_full(o) },
              count: operations.size
            )
          end

          # GET /api/v1/system/node_api/status/tasks/:id
          # Show a single task by id. Used by the agent's task lease
          # loop crash-recovery path: on restart, the agent walks its
          # local inflight state file and queries the platform for
          # each entry to decide whether to re-execute (non-terminal)
          # or drop (complete/failed/cancelled).
          def show_task
            operation = current_instance.tasks.find(params[:id])
            render_success(task: serialize_operation_full(operation))
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("Operation")
          end

          # POST /api/v1/system/node_api/status/operations/:id/ack
          # Acknowledge operation receipt
          def acknowledge_task
            operation = current_instance.tasks.find(params[:id])

            if operation.pending?
              operation.update!(
                status: "acknowledged",
                events: (operation.events || []) << {
                  type: "acknowledged",
                  message: "Acknowledged by instance",
                  timestamp: Time.current.iso8601
                }
              )
            end

            render_success(
              task: serialize_task(operation),
              acknowledged: true
            )
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("Operation")
          end

          # POST /api/v1/system/node_api/status/operations/:id/complete
          # Report operation completion
          def complete_task
            operation = current_instance.tasks.find(params[:id])

            unless operation.running? || operation.status == "acknowledged"
              return render_error("Operation cannot be completed from #{operation.status} state")
            end

            result = params[:result] || {}
            message = params[:message] || "Completed by instance"

            operation.update!(
              status: "complete",
              progress: 100,
              completed_at: Time.current,
              result: result,
              events: (operation.events || []) << {
                type: "completed",
                message: message,
                timestamp: Time.current.iso8601
              }
            )

            render_success(
              task: serialize_task(operation),
              completed: true
            )
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("Operation")
          end

          # POST /api/v1/system/node_api/status/operations/:id/fail
          # Report operation failure
          def fail_task
            operation = current_instance.tasks.find(params[:id])

            unless operation.pending? || operation.running? || operation.status == "acknowledged"
              return render_error("Operation cannot be marked as failed from #{operation.status} state")
            end

            error_message = params[:error_message] || "Failed by instance"

            operation.update!(
              status: "failed",
              completed_at: Time.current,
              error_message: error_message,
              events: (operation.events || []) << {
                type: "failed",
                message: error_message,
                timestamp: Time.current.iso8601
              }
            )

            render_success(
              task: serialize_task(operation),
              failed: true
            )
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("Operation")
          end

          private

          def serialize_instance_status
            {
              id: current_instance.id,
              name: current_instance.name,
              status: current_instance.status,
              variety: current_instance.variety,
              last_heartbeat: current_instance.config&.dig("last_heartbeat"),
              last_report: current_instance.config&.dig("last_report"),
              metrics: current_instance.config&.dig("metrics")
            }
          end

          def serialize_node_status
            {
              id: current_node.id,
              name: current_node.name,
              worker_assigned: current_node.worker_id.present?
            }
          end

          def pending_tasks
            current_instance.tasks.where(status: %w[pending acknowledged running])
          end

          def pending_operations_count
            pending_tasks.count
          end

          def serialize_task(operation)
            {
              id: operation.id,
              command: operation.command,
              status: operation.status,
              progress: operation.progress,
              created_at: operation.created_at
            }
          end

          def serialize_operation_full(operation)
            serialize_task(operation).merge(
              options: operation.options,
              started_at: operation.started_at,
              events: operation.events || []
            )
          end
        end
      end
    end
  end
end
