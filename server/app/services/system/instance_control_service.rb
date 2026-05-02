# frozen_string_literal: true

module System
  # Controls instance lifecycle (start, stop, reboot, terminate) across
  # cloud and physical varieties via provider adapters and SSH/IPMI fallbacks.
  #
  # Returns System::Runtime::Result. The service is the platform-shaped
  # boundary; provider adapters below it still return hashes (cloud-shaped).
  class InstanceControlService
    class ControlError < StandardError; end

    def self.execute(instance:, action:, operation_id: nil, force: false)
      new.execute(instance: instance, action: action, operation_id: operation_id, force: force)
    end

    def execute(instance:, action:, operation_id: nil, force: false)
      validate_instance!(instance)
      validate_action!(action)

      Rails.logger.info("[InstanceControlService] Executing #{action} on #{instance.name}")

      unless can_execute_action?(instance, action)
        return Runtime::Result.err(error: "Cannot #{action} instance in #{instance.status} status")
      end

      update_transitional_status(instance, action)

      adapter_result = case instance.variety
                       when "cloud", "dynamic" then execute_cloud_action(instance, action, force: force)
                       when "physical"          then execute_physical_action(instance, action)
                       else { success: false, error: "Unknown instance variety: #{instance.variety}" }
                       end

      if adapter_result[:success]
        update_instance_from_result(instance, adapter_result)
        Runtime::Result.ok(data: adapter_result.except(:success))
      else
        revert_status(instance)
        Runtime::Result.err(error: adapter_result[:error] || "Control action failed", data: adapter_result)
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[InstanceControlService] Provider error: #{e.message}")
      revert_status(instance)
      Runtime::Result.err(error: e.message)
    rescue StandardError => e
      Rails.logger.error("[InstanceControlService] #{action} failed: #{e.message}")
      revert_status(instance)
      Runtime::Result.err(error: e.message)
    end

    private

    def validate_instance!(instance)
      raise ArgumentError, "Instance required" unless instance
      raise ArgumentError, "Instance must be a System::NodeInstance" unless instance.is_a?(::System::NodeInstance)
    end

    def validate_action!(action)
      valid_actions = %i[start stop reboot terminate]
      raise ArgumentError, "Invalid action: #{action}" unless valid_actions.include?(action.to_sym)
    end

    def can_execute_action?(instance, action)
      case action.to_sym
      when :start     then instance.may_start?
      when :stop      then instance.may_stop?
      when :reboot    then instance.may_reboot?
      when :terminate then instance.may_terminate?
      else false
      end
    end

    def update_transitional_status(instance, action)
      # AASM event maps directly to the transitional state. Whiny transitions
      # raise on misuse — callers must guard with `can_execute_action?` first.
      instance.public_send("#{action}!")
    end

    def update_instance_from_result(instance, result)
      # State changes flow through AASM events (platform-standard); IP fields
      # update independently and don't go through the state machine.
      finalize_state_from_result(instance, result[:status]) if result[:status].present?

      ip_updates = {}
      ip_updates[:private_ip_address] = result[:private_ip_address] if result.key?(:private_ip_address)
      ip_updates[:public_ip_address]  = result[:public_ip_address]  if result.key?(:public_ip_address)
      instance.update!(ip_updates) if ip_updates.any?
    end

    # Map provider-reported status to the matching AASM finalizer event.
    # Each event has a may? guard — if the instance is already in a terminal
    # state (or invalid for this transition), the call is a safe no-op.
    def finalize_state_from_result(instance, reported_status)
      event = case reported_status
              when "running"    then :mark_running
              when "stopped"    then :mark_stopped
              when "terminated" then :mark_terminated
              when "error"      then :mark_errored
              end
      return unless event && instance.public_send("may_#{event}?")
      instance.public_send("#{event}!")
    end

    def revert_status(instance)
      # Failed transitional state → revert to last-known-good via AASM finalizer.
      # `may_X?` guards prevent invalid transitions if the instance somehow
      # already moved further (e.g., another worker updated state).
      case instance.status
      when "starting"  then instance.mark_stopped! if instance.may_mark_stopped?
      when "stopping"  then instance.mark_running! if instance.may_mark_running?
      when "rebooting" then instance.mark_running! if instance.may_mark_running?
      end
    end

    # Returns a hash (cloud-shape) from the provider adapter, post-decorated
    # with the platform's canonical `:status` value.
    def execute_cloud_action(instance, action, force: false)
      unless instance.cloud_instance_id.present?
        return { success: false, error: "Instance has no cloud instance ID" }
      end

      provider_adapter = begin
        Providers::Registry.for_instance(instance)
      rescue Providers::Registry::UnknownProviderError => e
        return { success: false, error: e.message }
      end

      Rails.logger.info("[InstanceControlService] Using #{provider_adapter.provider_type} for #{action}")

      case action.to_sym
      when :start
        result = provider_adapter.start_instance(instance.cloud_instance_id)
        result[:status] = "running" if result[:success]
        result
      when :stop
        result = provider_adapter.stop_instance(instance.cloud_instance_id, force: force)
        result[:status] = "stopped" if result[:success]
        result
      when :reboot
        result = provider_adapter.reboot_instance(instance.cloud_instance_id)
        result[:status] = "running" if result[:success]
        result
      when :terminate
        result = provider_adapter.terminate_instance(instance.cloud_instance_id)
        result[:status] = "terminated" if result[:success]
        result
      else
        { success: false, error: "Unknown action: #{action}" }
      end
    end

    def execute_physical_action(instance, action)
      case action.to_sym
      when :start     then execute_physical_start(instance)
      when :stop      then execute_physical_stop(instance)
      when :reboot    then execute_physical_reboot(instance)
      when :terminate then { success: true, status: "terminated" }
      end
    end

    def execute_physical_start(instance)
      ipmi_config = instance.config&.dig("ipmi")

      if ipmi_config.present?
        Rails.logger.info("[InstanceControlService] IPMI power on for #{instance.name}")
        { success: true, status: "running" }
      elsif instance.config&.dig("mac_address").present?
        Rails.logger.info("[InstanceControlService] Wake-on-LAN for #{instance.name}")
        { success: true, status: "starting" }
      else
        { success: false, error: "No IPMI or WoL configuration available" }
      end
    end

    def execute_physical_stop(instance)
      if instance.private_ip_address.present?
        ssh_result = SshExecutionService.execute(
          instance: instance,
          command: "shutdown -h now",
          sudo: true
        )
        return { success: true, status: "stopped" } if ssh_result.success?
      end

      ipmi_config = instance.config&.dig("ipmi")
      if ipmi_config.present?
        Rails.logger.info("[InstanceControlService] IPMI power off for #{instance.name}")
        { success: true, status: "stopped" }
      else
        { success: false, error: "Cannot stop physical instance - no SSH or IPMI available" }
      end
    end

    def execute_physical_reboot(instance)
      if instance.private_ip_address.present?
        ssh_result = SshExecutionService.execute(
          instance: instance,
          command: "reboot",
          sudo: true
        )
        return { success: true, status: "running" } if ssh_result.success?
      end

      ipmi_config = instance.config&.dig("ipmi")
      if ipmi_config.present?
        Rails.logger.info("[InstanceControlService] IPMI power cycle for #{instance.name}")
        { success: true, status: "rebooting" }
      else
        { success: false, error: "Cannot reboot physical instance - no SSH or IPMI available" }
      end
    end
  end
end
