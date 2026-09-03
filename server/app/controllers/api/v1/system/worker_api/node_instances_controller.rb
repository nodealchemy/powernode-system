# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Node instance lifecycle management for infrastructure workers
        # Handles instance CRUD and state transitions
        class NodeInstancesController < BaseController
          before_action :set_instance, only: [ :show, :update, :destroy, :start, :stop, :reboot, :sync, :maintenance ]

          # GET /api/v1/system/worker_api/node_instances
          # List instances for nodes managed by this worker
          def index
            authorize_worker_permission!("system.node_instances.read")

            instances = ::System::NodeInstance
                        .joins(:node)
                        .where(system_nodes: { worker_id: current_worker.id })
            instances = apply_filters(instances)
            instances = paginate(instances.includes(:node, :provider_region))

            render_success(
              instances: instances.map { |i| serialize_instance(i) },
              meta: pagination_meta
            )
          end

          # GET /api/v1/system/worker_api/node_instances/:id
          def show
            authorize_worker_permission!("system.node_instances.read")
            render_success(instance: serialize_instance_full(@instance))
          end

          # POST /api/v1/system/worker_api/node_instances
          # Create new instance (typically from provisioning job)
          def create
            authorize_worker_permission!("system.node_instances.create")

            # The tenancy-scoped lookup stays FIRST: a node this worker does not
            # manage must still answer 404, not a 422 about its request body.
            node = ::System::Node.where(worker: current_worker).find(params[:node_id])

            document, refusal = config_document_or_refusal
            return render_error(refusal, status: :unprocessable_content) if refusal

            attrs = instance_params
            # Creation: no row behind the object yet, nothing to clobber.
            attrs = attrs.merge(config: document) if document
            instance = node.node_instances.build(attrs)

            if instance.save
              render_success(instance: serialize_instance(instance), status: :created)
            else
              render_validation_error(instance)
            end
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("Node")
          end

          # PUT /api/v1/system/worker_api/node_instances/:id
          # Update instance (IP addresses, cloud IDs, status)
          def update
            authorize_worker_permission!("system.node_instances.update")
            document, refusal = config_document_or_refusal
            return render_error(refusal, status: :unprocessable_content) if refusal

            if @instance.update(instance_update_params)
              # Per-key, in Postgres, against the CURRENT row. The worker holds
              # an instance across a provider round trip, which is exactly the
              # interval the node's telemetry lanes write in.
              @instance.merge_config!(document) if document.present?
              render_success(instance: serialize_instance(@instance))
            else
              render_validation_error(@instance)
            end
          end

          # DELETE /api/v1/system/worker_api/node_instances/:id
          def destroy
            authorize_worker_permission!("system.node_instances.delete")

            if @instance.destroy
              render_success(message: "Instance deleted successfully")
            else
              render_error("Failed to delete instance: #{@instance.errors.full_messages.join(', ')}")
            end
          end

          # POST /api/v1/system/worker_api/node_instances/:id/start
          def start
            authorize_worker_permission!("system.node_instances.manage")
            execute_instance_action(:start)
          end

          # POST /api/v1/system/worker_api/node_instances/:id/stop
          def stop
            authorize_worker_permission!("system.node_instances.manage")
            execute_instance_action(:stop)
          end

          # POST /api/v1/system/worker_api/node_instances/:id/reboot
          def reboot
            authorize_worker_permission!("system.node_instances.manage")
            execute_instance_action(:reboot)
          end

          # POST /api/v1/system/worker_api/node_instances/:id/sync
          # Reflects cloud-reported instance state into the platform.
          # InstanceControlService has no "sync" action (only
          # start/stop/reboot/terminate) — CloudSyncService is the boundary
          # that reads the provider's current state, same as the internal
          # API's #sync_cloud_state.
          def sync
            authorize_worker_permission!("system.node_instances.manage")

            result = ::System::CloudSyncService.sync_instance_state(instance: @instance)

            if result.success?
              data = result.data
              finalize_state_from_cloud(data[:status])

              ip_updates = {}
              ip_updates[:private_ip_address] = data[:private_ip_address] if data.key?(:private_ip_address)
              ip_updates[:public_ip_address]  = data[:public_ip_address]  if data.key?(:public_ip_address)
              @instance.update!(ip_updates) if ip_updates.any?

              render_success(
                instance: serialize_instance(@instance.reload),
                action: :sync,
                result: { success: true, status: data[:status], updated: data[:updated] }
              )
            else
              render_error(result.error || "Sync failed")
            end
          end

          # POST /api/v1/system/worker_api/node_instances/:id/maintenance
          # Run maintenance tasks (sync cloud state)
          def maintenance
            authorize_worker_permission!("system.node_instances.manage")

            result = ::System::InstanceMaintenanceService.run_maintenance(instance: @instance)

            if result.success?
              render_success(
                instance: serialize_instance(@instance.reload),
                maintenance_result: {
                  success: result.success?,
                  tasks_run: result.data[:tasks_run],
                  tasks_succeeded: result.data[:tasks_succeeded],
                  tasks_failed: result.data[:tasks_failed],
                  results: result.data[:results]
                }
              )
            else
              render_error(result.error || "Maintenance failed")
            end
          end

          private

          def set_instance
            @instance = ::System::NodeInstance
                        .joins(:node)
                        .where(system_nodes: { worker_id: current_worker.id })
                        .find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("NodeInstance")
          end

          def instance_params
            require_object_root(:instance).permit(
              :name, :variety, :status,
              :provider_region_id, :provider_instance_type_id,
              :provider_availability_zone_id,
              :private_ip_address, :public_ip_address,
              :cloud_instance_id
            )
          end

          def instance_update_params
            require_object_root(:instance).permit(
              :status,
              :private_ip_address, :public_ip_address,
              :cloud_instance_id
            )
          end

          # `params.require` hands back whatever NON-BLANK value sits under the
          # key, so a String / Array / scalar root came back as itself and the
          # `.permit` on it was a NoMethodError — a 500 through the
          # StandardError rescue (IMP-f9a184e832ac). Only an object can be
          # permitted; any other root is the same request defect as an absent
          # one and is reported the same way: ActionController::ParameterMissing,
          # which the ApiResponse base rescue renders as 400 PARAMETER_MISSING.
          # Raising (not rendering) matters — it unwinds the action before
          # `update`/`build` runs.
          def require_object_root(key)
            root = params.require(key)
            return root if root.is_a?(ActionController::Parameters)

            raise ActionController::ParameterMissing.new(key, params.keys)
          end

          # `config` is deliberately absent from BOTH permit lists above
          # (IMP-1b65222b8d5f): `permit(config: {})` admits an arbitrary
          # document and `update` then replaces the column, erasing whatever
          # the node reported in the interval. The document is read whole here
          # and checked against System::NodeInstance::WRITABLE_CONFIG_KEYS
          # instead; accepted keys go through the per-key seam.
          #
          # Returns [document_or_nil, refusal_message_or_nil]. No `config` in
          # the body yields [nil, nil] — and so does a malformed `instance`
          # root, leaving #require_object_root (via the permit helpers) as the
          # one place that reports that, as a 400 (digging into a String root
          # here would raise, and make it a 500 again).
          def config_document_or_refusal
            root = params[:instance]
            return [ nil, nil ] unless root.is_a?(ActionController::Parameters) || root.is_a?(Hash)

            raw = root[:config]
            return [ nil, nil ] if raw.nil?

            document = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
            return [ nil, "config must be an object of top-level keys" ] unless document.is_a?(Hash)

            document = document.deep_stringify_keys
            refused  = ::System::NodeInstance.unwritable_config_keys(document)
            return [ nil, ::System::NodeInstance.config_refusal_message(refused) ] if refused.any?

            [ document, nil ]
          end

          def apply_filters(scope)
            scope = scope.where(variety: params[:variety]) if params[:variety].present?
            scope = scope.where(status: params[:status]) if params[:status].present?
            scope = scope.where(node_id: params[:node_id]) if params[:node_id].present?
            scope.order(created_at: :desc)
          end

          def execute_instance_action(action)
            result = ::System::InstanceControlService.execute(
              instance: @instance,
              action: action,
              operation_id: params[:operation_id]
            )

            if result.success?
              render_success(
                instance: serialize_instance(@instance.reload),
                action: action,
                result: { success: true }.merge(result.data)
              )
            else
              render_error(result.error || "#{action.to_s.humanize} failed")
            end
          end

          # Map cloud-reported status to the matching AASM finalizer event.
          # `may_X?` guard makes the call a safe no-op if the instance is
          # already in a terminal state or was already moved by another
          # worker (same pattern as the internal API controller).
          def finalize_state_from_cloud(reported_status)
            event = case reported_status
            when "running"    then :mark_running
            when "stopped"    then :mark_stopped
            when "terminated" then :mark_terminated
            when "error"      then :mark_errored
            end
            return unless event && @instance.public_send("may_#{event}?")
            @instance.public_send("#{event}!")
          end

          def serialize_instance(instance)
            {
              id: instance.id,
              name: instance.name,
              node_id: instance.node_id,
              variety: instance.variety,
              status: instance.status,
              private_ip_address: instance.private_ip_address,
              public_ip_address: instance.public_ip_address,
              cloud_instance_id: instance.cloud_instance_id,
              provider_region_id: instance.provider_region_id,
              created_at: instance.created_at,
              updated_at: instance.updated_at
            }
          end

          def serialize_instance_full(instance)
            serialize_instance(instance).merge(
              node: {
                id: instance.node.id,
                name: instance.node.name,
                template_id: instance.node.node_template_id
              },
              config: instance.config,
              provider_region: instance.provider_region ? {
                id: instance.provider_region.id,
                name: instance.provider_region.name,
                region_code: instance.provider_region.region_code
              } : nil,
              provider_instance_type: instance.provider_instance_type ? {
                id: instance.provider_instance_type.id,
                name: instance.provider_instance_type.name
              } : nil
            )
          end
        end
      end
    end
  end
end
