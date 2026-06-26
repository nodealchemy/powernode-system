# frozen_string_literal: true

module System
  # Lifecycle-control plumbing for NodeInstancesController, extracted to keep the
  # controller focused on action routing (start/stop/reboot/terminate +
  # public-IP association/disassociation). Drives every instance lifecycle
  # action through the Ai::AutonomyGate for uniform audit + chain-of-custody,
  # and runs the synchronous local-hypervisor (qemu/libvirt) provider calls
  # inline so operators see immediate results.
  #
  # Behavior-preserving relocation: response shapes, status codes, gate
  # semantics and AASM transitions are identical to the inline originals.
  module NodeInstanceGating
    extend ActiveSupport::Concern

    private

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
            status: :unprocessable_content
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
          status: :unprocessable_content
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
