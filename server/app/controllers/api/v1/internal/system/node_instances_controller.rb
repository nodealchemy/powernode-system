# frozen_string_literal: true

module Api
  module V1
    module Internal
      module System
        # Internal API for system node instance operations: SSH execution,
        # AASM lifecycle control, IP management, image creation, maintenance,
        # and cloud-state sync. Worker-only — accessed via the worker token
        # at the parent InternalBaseController.
        class NodeInstancesController < BaseController
          before_action :set_instance, except: %i[index create]

          # Centralize the per-action "rescue StandardError -> log -> 500"
          # boilerplate. Every internal action below either succeeds, returns
          # an explicit 422, or falls through here to a logged 500.
          rescue_from StandardError, with: :handle_internal_error

          # GET /api/v1/internal/system/node_instances
          def index
            instances = ::System::NodeInstance.all
            instances = instances.where(node_id: params[:node_id]) if params[:node_id].present?
            instances = instances.where(variety: Array(params[:variety])) if params[:variety].present?
            instances = instances.where(status: params[:status]) if params[:status].present?

            if params[:for_health_check].present?
              instances = instances.where(status: %w[running starting stopping])
            end

            instances = instances.includes(:node, :provider_region).limit(params[:limit] || 100)

            render_success(
              data: { node_instances: instances.map { |i| serialize_instance(i) } }
            )
          end

          # GET /api/v1/internal/system/node_instances/:id
          def show
            render_success(data: serialize_instance(@instance))
          end

          # POST /api/v1/internal/system/node_instances/:id/start
          def start
            render_control_result(control_instance(:start), "start")
          end

          # POST /api/v1/internal/system/node_instances/:id/stop
          def stop
            render_control_result(control_instance(:stop), "stop")
          end

          # POST /api/v1/internal/system/node_instances/:id/reboot
          def reboot
            render_control_result(control_instance(:reboot), "reboot")
          end

          # POST /api/v1/internal/system/node_instances/:id/terminate
          def terminate
            render_control_result(control_instance(:terminate), "terminate")
          end

          # POST /api/v1/internal/system/node_instances/:id/ssh_exec
          def ssh_exec
            return render_error("Command is required", status: :unprocessable_entity) if params[:command].blank?

            result = ::System::SshExecutionService.execute(
              instance: @instance,
              command: params[:command],
              sudo: params[:sudo] != false,
              operation_id: params[:operation_id]
            )

            render_success(
              data: result.slice(:success, :stdout, :stderr, :exit_code, :error)
            )
          end

          # POST /api/v1/internal/system/node_instances/:id/ssh_sync
          def ssh_sync
            result = ::System::SshExecutionService.sync(instance: @instance)
            @instance.update(last_synced_at: Time.current) if result[:success]
            render_success(data: result.slice(:success, :error))
          end

          # POST /api/v1/internal/system/node_instances/:id/ssh_cleanse
          def ssh_cleanse
            result = ::System::SshExecutionService.cleanse(instance: @instance)
            render_success(data: result.slice(:success, :error))
          end

          # POST /api/v1/internal/system/node_instances/:id/associate_public_ip
          def associate_public_ip
            result = ::System::IpManagementService.associate_public_ip(instance: @instance)
            render_or_error(result, data: { success: true, public_ip_address: result[:public_ip_address] })
          end

          # POST /api/v1/internal/system/node_instances/:id/disassociate_public_ip
          def disassociate_public_ip
            result = ::System::IpManagementService.disassociate_public_ip(instance: @instance)
            render_or_error(result, data: { success: true })
          end

          # POST /api/v1/internal/system/node_instances/:id/create_image
          def create_image
            image_format = params[:image_format] || "img"
            return render_error("Invalid image format", status: :unprocessable_entity) unless %w[img iso].include?(image_format)

            result = ::System::ImageCreationService.create_instance_image(
              instance: @instance,
              format: image_format,
              operation_id: params[:operation_id]
            )

            render_or_error(result, data: {
              success: true,
              image_path: result[:image_path],
              image_size: result[:image_size]
            })
          end

          # POST /api/v1/internal/system/node_instances/:id/maintenance
          def maintenance
            result = ::System::InstanceMaintenanceService.run_maintenance(instance: @instance)
            render_success(data: {
              success: result.success?,
              tasks_run: result.data[:tasks_run],
              tasks_succeeded: result.data[:tasks_succeeded],
              tasks_failed: result.data[:tasks_failed],
              error: result.error
            })
          end

          # POST /api/v1/internal/system/node_instances/:id/sync_cloud_state
          # Reflects cloud-reported state into the platform via AASM finalizers
          # so the state-machine invariants stay intact. IPs and timestamps
          # update independently of the state machine.
          def sync_cloud_state
            result = ::System::CloudSyncService.sync_instance_state(instance: @instance)
            return render_error(result.error, status: :unprocessable_entity) unless result.success?

            data = result.data
            finalize_state_from_cloud(@instance, data[:status])

            ip_updates = { last_synced_at: Time.current }
            ip_updates[:private_ip_address] = data[:private_ip_address] if data.key?(:private_ip_address)
            ip_updates[:public_ip_address]  = data[:public_ip_address]  if data.key?(:public_ip_address)
            @instance.update!(ip_updates)

            render_success(
              data: {
                success: true,
                status: @instance.reload.status,
                private_ip_address: @instance.private_ip_address,
                public_ip_address: @instance.public_ip_address,
                updated: data[:updated]
              }
            )
          end

          # POST /api/v1/internal/system/node_instances/:id/sync_netboot
          def sync_netboot
            unless @instance.variety == "physical"
              return render_error("Netboot sync only available for physical instances", status: :unprocessable_entity)
            end

            result = ::System::NetbootService.sync(instance: @instance)
            render_or_error(result, data: { success: true })
          end

          # DELETE /api/v1/internal/system/node_instances/:id
          # Cleanup of terminated instance rows. Validation prevents accidental
          # deletion of a still-attached cloud resource.
          def destroy
            return render_error("Can only delete terminated instances", status: :unprocessable_entity) unless @instance.terminated?

            @instance.destroy!
            render_success(data: { success: true, message: "Instance deleted" })
          end

          private

          def set_instance
            @instance = ::System::NodeInstance.find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("NodeInstance")
          end

          def control_instance(action)
            ::System::InstanceControlService.execute(
              instance: @instance,
              action: action,
              operation_id: params[:operation_id]
            )
          end

          def render_control_result(result, action)
            return render_error(result[:error], status: :unprocessable_entity) unless result[:success]

            render_success(
              data: {
                success: true,
                instance_id: @instance.id,
                action: action,
                new_status: @instance.reload.status
              }
            )
          end

          # Render success or 422 based on a service result hash.
          def render_or_error(result, data:)
            if result[:success]
              render_success(data: data)
            else
              render_error(result[:error], status: :unprocessable_entity)
            end
          end

          def serialize_instance(instance)
            ::System::NodeInstanceInternalSerializer.new(instance).as_json
          end

          def handle_internal_error(error)
            Rails.logger.error("[System::NodeInstances] #{error.class}: #{error.message}")
            render_error(error.message, status: :internal_server_error)
          end

          # Map cloud-reported status to the matching AASM finalizer event.
          # `may_X?` guard makes the call a safe no-op when the instance is
          # already in a terminal state or already in the target state.
          def finalize_state_from_cloud(instance, reported_status)
            event = case reported_status
            when "running"    then :mark_running
            when "stopped"    then :mark_stopped
            when "terminated" then :mark_terminated
            when "error"      then :mark_errored
            end
            return unless event && instance.public_send("may_#{event}?")
            instance.public_send("#{event}!")
          end
        end
      end
    end
  end
end
