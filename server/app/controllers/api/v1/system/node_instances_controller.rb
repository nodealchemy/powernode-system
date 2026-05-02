# frozen_string_literal: true

module Api
  module V1
    module System
      class NodeInstancesController < BaseController
        before_action :set_account
        before_action :set_node
        before_action :set_instance, only: [
          :show, :update, :destroy,
          :start, :stop, :reboot, :terminate,
          :associate_public_ip, :disassociate_public_ip
        ]

        def index
          require_permission("system.instances.read")
          instances = @node.node_instances
          instances = apply_filters(instances)
          instances = paginate(instances)
          render_success(node_instances: serialize_collection(instances), meta: pagination_meta)
        end

        def show
          require_permission("system.instances.read")
          render_success(node_instance: serialize_instance(@instance))
        end

        def create
          require_permission("system.instances.create")
          instance = @node.node_instances.build(instance_params)

          if instance.save
            render_success(node_instance: serialize_instance(instance), status: :created)
          else
            render_validation_error(instance)
          end
        end

        def update
          require_permission("system.instances.update")

          if @instance.update(instance_params)
            render_success(node_instance: serialize_instance(@instance))
          else
            render_validation_error(@instance)
          end
        end

        def destroy
          require_permission("system.instances.delete")

          if @instance.destroy
            render_success(message: "Instance deleted successfully")
          else
            render_error("Failed to delete instance", status: :unprocessable_entity)
          end
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/start
        def start
          require_permission("system.instances.control")
          control_or_error(:start)
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/stop
        def stop
          require_permission("system.instances.control")
          control_or_error(:stop)
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/reboot
        def reboot
          require_permission("system.instances.control")
          control_or_error(:reboot)
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/terminate
        # Unlike DELETE (which removes the row), terminate keeps the row and
        # the worker runtime brings the cloud resource down via an operation.
        def terminate
          require_permission("system.instances.control")
          control_or_error(:terminate)
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/associate_public_ip
        # Allocates and associates a public/elastic IP. Cloud-only; physical
        # instances reject. The actual cloud-side allocation happens in the
        # worker runtime via the operation pipeline.
        def associate_public_ip
          require_permission("system.instances.control")

          unless @instance.cloud?
            return render_error(
              "Public IP association is only valid for cloud instances (variety: #{@instance.variety})",
              status: :unprocessable_entity
            )
          end

          operation = create_instance_operation("associate_public_ip")
          render_success(
            node_instance: serialize_instance(@instance.reload),
            task: operation ? ::System::TaskSerializer.new(operation).as_json : nil
          )
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/disassociate_public_ip
        # Releases the currently-associated public IP back to the cloud pool.
        def disassociate_public_ip
          require_permission("system.instances.control")

          unless @instance.cloud?
            return render_error(
              "Public IP disassociation is only valid for cloud instances",
              status: :unprocessable_entity
            )
          end

          if @instance.public_ip_address.blank?
            return render_error(
              "No public IP currently associated with this instance",
              status: :unprocessable_entity
            )
          end

          operation = create_instance_operation("disassociate_public_ip")
          render_success(
            node_instance: serialize_instance(@instance.reload),
            task: operation ? ::System::TaskSerializer.new(operation).as_json : nil
          )
        end

        private

        # Run an AASM transition with the platform-standard "may? then bang"
        # pattern, then create an Operation that the worker runtime will
        # execute. The state machine moves the instance into a transitional
        # state ("starting", "stopping", etc.); the runtime finalizes via
        # mark_running / mark_stopped / mark_terminated.
        def control_or_error(event)
          unless @instance.public_send("may_#{event}?")
            return render_error(
              "Cannot #{event} instance in #{@instance.status} state",
              status: :unprocessable_entity
            )
          end
          @instance.public_send("#{event}!")
          operation = create_instance_operation(event.to_s)
          render_success(
            node_instance: serialize_instance(@instance.reload),
            task: operation ? ::System::TaskSerializer.new(operation).as_json : nil
          )
        end

        def set_node
          @node = @account.system_nodes.find(params[:node_id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node")
        end

        def set_instance
          @instance = @node.node_instances.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node Instance")
        end

        def instance_params
          params.require(:node_instance).permit(
            :name, :description, :variety, :status, :key,
            :private_ip_address, :public_ip_address, :vpn_ip_address,
            config: {}
          )
        end

        def apply_filters(scope)
          scope = scope.where(variety: params[:variety]) if params[:variety].present?
          scope = scope.where(status: params[:status]) if params[:status].present?
          scope
        end

        def serialize_instance(instance)
          ::System::NodeInstanceSerializer.new(instance).as_json
        end

        def serialize_collection(instances)
          instances.map { |i| serialize_instance(i) }
        end

        def create_instance_operation(command)
          return nil unless current_account.respond_to?(:system_tasks)

          current_account.system_tasks.create(
            command: command,
            description: "#{command.capitalize} node instance: #{@instance.name}",
            operable: @instance,
            initiated_by: current_user,
            status: "pending"
          )
        rescue StandardError => e
          Rails.logger.error "Failed to create operation: #{e.message}"
          nil
        end
      end
    end
  end
end
