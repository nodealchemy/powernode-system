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
          # Lazy reconcile: in-flight instances (status=pending/provisioning/starting/
          # stopping/rebooting) get a live status pull from their provider before we
          # serialize. Cheap on local_qemu (one virsh dominfo per instance, ~50ms);
          # cloud providers gate themselves on rate limits internally.
          instances = instances.to_a
          reconcile_in_flight_statuses!(instances)
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
        # All instance lifecycle actions flow through the autonomy gate for
        # uniform audit + chain-of-custody. Manual operation policies default
        # start/stop/restart/reboot to auto_approve, so steady-state behavior
        # is identical — but operators can flip any of them to require_approval
        # from the System Settings → Manual Operations tab if they want a
        # double-check before bouncing nodes.
        def start
          require_permission("system.instances.control")
          gate_or_execute(:start)
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/stop
        def stop
          require_permission("system.instances.control")
          gate_or_execute(:stop)
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/reboot
        def reboot
          require_permission("system.instances.control")
          gate_or_execute(:reboot)
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/terminate
        # Unlike DELETE (which removes the row), terminate keeps the row and
        # the worker runtime brings the cloud resource down via an operation.
        #
        # Gated through Ai::AutonomyGate — system.task.terminate defaults to
        # require_approval in the manual operation policies seed. If the
        # operator's account has it set to auto_approve, terminate executes
        # immediately as before.
        def terminate
          require_permission("system.instances.control")
          gate_or_execute(:terminate)
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

          if (msg = local_hypervisor_rejection_message)
            return render_error(msg, status: :unprocessable_entity)
          end

          gate_ip_action(:associate_public_ip)
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

          if (msg = local_hypervisor_rejection_message)
            return render_error(msg, status: :unprocessable_entity)
          end

          if @instance.public_ip_address.blank?
            return render_error(
              "No public IP currently associated with this instance",
              status: :unprocessable_entity
            )
          end

          gate_ip_action(:disassociate_public_ip)
        end

        private

        # Transitional states are AASM-driven assertions of operator intent
        # ("user clicked Start"). Reconciling against the provider while one
        # of these is the live status produces races where a fast poll
        # overwrites the intent before the actual provider operation has run.
        # Reconcile only when the instance is in a stable, terminal-ish state.
        TRANSITIONAL_STATUSES = %w[starting stopping rebooting].freeze
        IN_FLIGHT_STATUSES    = %w[pending provisioning].freeze
        # The set we consider safe to commit FROM a transitional state. A poll
        # in the middle of `starting` should only update the model if the
        # provider has resolved to one of these terminal-ish states; a sideways
        # flip from `starting` back to `starting` (or to a non-terminal value)
        # is suppressed.
        TERMINAL_STATUSES = %w[running stopped terminated error].freeze

        # Returns a rejection message if the instance is on a provider that has no
        # public-IP concept (i.e. local hypervisors). nil = allowed.
        def local_hypervisor_rejection_message
          provider = @instance.provider_region&.provider
          return nil unless provider&.provider_type == "local_qemu"
          ip_hint = @instance.private_ip_address.presence || "pending"
          "Public IP allocation is not supported for local hypervisor instances. " \
            "Connect via the private IP (#{ip_hint}) from the host, or configure " \
            "the provider with a bridged network for routable LAN addressing."
        end

        # Lazily reconcile in-flight instances against their provider. Mutates
        # the array elements in place so the subsequent serialize sees fresh
        # rows. Failures are swallowed per-instance — a stale read is better
        # than failing the whole index call.
        #
        # Three reconcile modes:
        #   - in_flight: status was pending/provisioning → accept any new status
        #   - transitional: status was starting/stopping/rebooting → accept new
        #     status only when it resolves to a terminal state (running/stopped/etc),
        #     never sideways from one transitional to another
        #   - ip_only: status is already running but private_ip_address is blank
        #     → re-poll the provider for IPs without touching status. This catches
        #     local_qemu instances whose DHCP lease lives in dnsmasq rather than
        #     being captured at provision time.
        def reconcile_in_flight_statuses!(instances)
          instances.each do |instance|
            in_flight     = IN_FLIGHT_STATUSES.include?(instance.status)
            transitional  = TRANSITIONAL_STATUSES.include?(instance.status)
            ip_only       = instance.status == "running" && instance.private_ip_address.blank?
            next unless in_flight || transitional || ip_only
            cloud_id = instance.config["cloud_instance_id"]
            next if cloud_id.blank?
            adapter = ::System::Providers::Registry.for_instance(instance)
            next unless adapter.respond_to?(:sync_status)
            result = adapter.sync_status(cloud_id)
            next unless result[:success]

            updates = {}
            new_status = result[:status]
            if new_status.present? && new_status != instance.status
              # From in-flight, accept any provider-reported status (the
              # platform-side row is just catching up to provider truth).
              # From transitional, only commit when the provider has resolved
              # to a terminal state — otherwise a fast poll mid-`starting`
              # could push us back to an earlier state and produce the
              # opposite UX bug from the one this guard is meant to prevent.
              # ip_only mode never changes status.
              if in_flight || (transitional && TERMINAL_STATUSES.include?(new_status))
                updates[:status] = new_status
              end
            end
            updates[:private_ip_address] = result[:private_ip_address] if result[:private_ip_address].present? && result[:private_ip_address] != instance.private_ip_address
            updates[:public_ip_address]  = result[:public_ip_address]  if result[:public_ip_address].present?  && result[:public_ip_address]  != instance.public_ip_address
            instance.update!(updates) if updates.any?
          rescue StandardError => e
            Rails.logger.warn("[NodeInstancesController] sync_status failed for #{instance.id}: #{e.class}: #{e.message}")
          end
        end

        # Run an AASM transition with the platform-standard "may? then bang"
        # pattern, then create an Operation that the worker runtime will
        # execute. The state machine moves the instance into a transitional
        # state ("starting", "stopping", etc.); the runtime finalizes via
        # mark_running / mark_stopped / mark_terminated.
        # Gate-aware wrapper around control_or_error. Consults the AutonomyGate
        # for the policy on `system.task.<event>` and either proceeds inline
        # (auto_approve / notify_and_proceed) or returns 202 + an approval
        # request that, on approval, recreates the instance op via the
        # ExecuteTask executor.
        def gate_or_execute(event)
          gate_result = ::Ai::AutonomyGate.evaluate(
            action_category: "system.task.#{event}",
            executor_class: "System::Executors::ExecuteTask",
            params: {
              task_attributes: {
                command: event.to_s,
                description: "#{event} #{@instance.class.name}##{@instance.id}",
                operable_type: @instance.class.name,
                operable_id: @instance.id,
                initiated_by_id: current_user.id
              }
            },
            account: current_account,
            requested_by: current_user,
            source_type: @instance.class.name,
            source_id: @instance.id,
            description: "#{event} instance #{@instance.id}"
          )

          case gate_result.decision
          when :proceed
            # Mirrors original control_or_error behaviour for the inline path.
            unless @instance.public_send("may_#{event}?")
              return render_error(
                "Cannot #{event} instance in #{@instance.status} state",
                status: :unprocessable_entity
              )
            end
            @instance.public_send("#{event}!")
            execute_local_provider_action_sync!(event) if local_hypervisor_instance?
            data = gate_result.result&.dig(:data) || {}
            task = data[:task_id] ? current_account.system_tasks.find_by(id: data[:task_id]) : nil
            render_success(
              node_instance: serialize_instance(@instance.reload),
              task: task ? ::System::TaskSerializer.new(task).as_json : nil
            )
          when :pending
            render_pending_approval(gate_result.deferred_operation,
                                    message: "Approval required to #{event} instance")
          when :blocked
            render_error(gate_result.error || "Action blocked by policy",
                         status: :unprocessable_content)
          end
        end

        # Variant of gate_or_execute for IP association/disassociation —
        # which don't go through the AASM lifecycle (no may_event? predicate)
        # but still need an audit row + the same gate semantics.
        def gate_ip_action(event)
          gate_result = ::Ai::AutonomyGate.evaluate(
            action_category: "system.task.#{event}",
            executor_class: "System::Executors::ExecuteTask",
            params: {
              task_attributes: {
                command: event.to_s,
                description: "#{event} #{@instance.class.name}##{@instance.id}",
                operable_type: @instance.class.name,
                operable_id: @instance.id,
                initiated_by_id: current_user.id
              }
            },
            account: current_account,
            requested_by: current_user,
            source_type: @instance.class.name,
            source_id: @instance.id,
            description: "#{event} on instance #{@instance.id}"
          )

          case gate_result.decision
          when :proceed
            data = gate_result.result&.dig(:data) || {}
            task = data[:task_id] ? current_account.system_tasks.find_by(id: data[:task_id]) : nil
            render_success(
              node_instance: serialize_instance(@instance.reload),
              task: task ? ::System::TaskSerializer.new(task).as_json : nil
            )
          when :pending
            render_pending_approval(gate_result.deferred_operation,
                                    message: "Approval required to #{event}")
          when :blocked
            render_error(gate_result.error || "Action blocked by policy",
                         status: :unprocessable_content)
          end
        end

        def control_or_error(event)
          unless @instance.public_send("may_#{event}?")
            return render_error(
              "Cannot #{event} instance in #{@instance.status} state",
              status: :unprocessable_entity
            )
          end
          @instance.public_send("#{event}!")
          operation = create_instance_operation(event.to_s)

          # Local hypervisor providers (qemu/libvirt) handle instance control
          # synchronously — `virsh start`/`stop`/etc. is sub-100ms. The Task/
          # Operation row stays as an audit record, but the actual provider
          # call fires in this request thread so the user sees the result
          # immediately. Cloud providers (AWS, GCP, etc.) keep the async
          # path: they take seconds to minutes and rely on the worker queue.
          execute_local_provider_action_sync!(event) if local_hypervisor_instance?

          render_success(
            node_instance: serialize_instance(@instance.reload),
            task: operation ? ::System::TaskSerializer.new(operation).as_json : nil
          )
        end

        def local_hypervisor_instance?
          @instance.provider_region&.provider&.provider_type == "local_qemu"
        end

        # Map AASM event → provider verb + post-success status. The provider
        # mutates the libvirt domain; we update the model status to match
        # the now-known reality (running/stopped/etc.) without waiting for
        # the next reconcile-on-read.
        def execute_local_provider_action_sync!(event)
          adapter = ::System::Providers::Registry.for_instance(@instance)
          cloud_id = @instance.config["cloud_instance_id"]
          return if cloud_id.blank?
          result = case event.to_sym
                   when :start  then adapter.start_instance(cloud_id)
                   when :stop   then adapter.stop_instance(cloud_id)
                   when :reboot then adapter.respond_to?(:reboot_instance) ? adapter.reboot_instance(cloud_id) : nil
                   when :terminate then adapter.terminate_instance(cloud_id)
                   end
          return unless result&.dig(:success)

          # Map provider's response status to NodeInstance.status. The provider
          # returns intermediate states (e.g. "starting" while the kernel boots);
          # we leave AASM-set status as-is for transitions and only overwrite
          # to terminal states (running/stopped/terminated) when the provider
          # confirms them.
          new_status = result[:status]
          if %w[running stopped terminated error].include?(new_status) && new_status != @instance.status
            @instance.update_column(:status, new_status)
          end
          if result[:private_ip_address].present?
            @instance.update_column(:private_ip_address, result[:private_ip_address])
          end
        rescue StandardError => e
          Rails.logger.warn("[NodeInstancesController] sync provider call failed (#{event}): #{e.class}: #{e.message}")
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
