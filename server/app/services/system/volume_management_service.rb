# frozen_string_literal: true

module System
  # Manages cloud storage volumes (provision/attach/detach/delete/check) via
  # provider adapters. Public methods return System::Runtime::Result.
  class VolumeManagementService
    class VolumeError < StandardError; end

    def self.attach(volume:, instance:, device: nil)
      new.attach(volume: volume, instance: instance, device: device)
    end

    def self.detach(volume:, force: false)
      new.detach(volume: volume, force: force)
    end

    def self.provision(account:, region:, volume_type:, size_gb:, options: {})
      new.provision(account: account, region: region, volume_type: volume_type, size_gb: size_gb, options: options)
    end

    def self.delete(volume:)
      new.delete(volume: volume)
    end

    def self.check(volume:)
      new.check(volume: volume)
    end

    def attach(volume:, instance:, device: nil)
      validate_volume!(volume)
      validate_instance!(instance)

      return Runtime::Result.err(error: "Volume has no cloud volume ID") unless volume.cloud_volume_id.present?
      return Runtime::Result.err(error: "Instance has no cloud instance ID") unless instance.cloud_instance_id.present?
      return Runtime::Result.err(error: "Volume is already attached") if volume.provider_volume_members.any?

      Rails.logger.info("[VolumeManagementService] Attaching volume #{volume.name} to #{instance.name}")

      provider_adapter = begin
        Providers::Registry.for_volume(volume)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      device ||= next_available_device(instance)
      result = provider_adapter.attach_volume(volume.cloud_volume_id, instance.cloud_instance_id, device: device)

      if result[:success]
        attached_device = result[:device] || device

        ::System::ProviderVolumeMember.create!(
          provider_volume: volume,
          node_instance: instance,
          device: attached_device
        )

        volume.update!(status: "attached")

        Runtime::Result.ok(data: { device: attached_device })
      else
        Runtime::Result.err(error: result[:error])
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[VolumeManagementService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError, VolumeError
      raise
    rescue StandardError => e
      Rails.logger.error("[VolumeManagementService] Attach failed: #{e.message}")
      Runtime::Result.err(error: e.message)
    end

    def detach(volume:, force: false)
      validate_volume!(volume)

      return Runtime::Result.err(error: "Volume has no cloud volume ID") unless volume.cloud_volume_id.present?

      member = volume.provider_volume_members.first
      return Runtime::Result.ok(data: { message: "Volume is not attached" }) unless member

      Rails.logger.info("[VolumeManagementService] Detaching volume #{volume.name}")

      provider_adapter = begin
        Providers::Registry.for_volume(volume)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      result = provider_adapter.detach_volume(volume.cloud_volume_id, force: force)

      if result[:success]
        member.destroy!
        volume.update!(status: "available")
        Runtime::Result.ok
      else
        Runtime::Result.err(error: result[:error])
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[VolumeManagementService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError
      raise
    rescue StandardError => e
      Rails.logger.error("[VolumeManagementService] Detach failed: #{e.message}")
      Runtime::Result.err(error: e.message)
    end

    def provision(account:, region:, volume_type:, size_gb:, options: {})
      validate_region!(region)

      Rails.logger.info("[VolumeManagementService] Provisioning #{size_gb}GB volume in #{region.name}")

      connection = Providers::Registry.find_connection_for_region(region, account)
      return Runtime::Result.err(error: "No provider connection available") unless connection

      provider_adapter = begin
        Providers::Registry.for(connection, region: region)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      volume = ::System::ProviderVolume.create!(
        name: options[:name] || "volume-#{Time.current.strftime('%Y%m%d%H%M%S')}",
        account: account,
        provider_region: region,
        provider_volume_type: volume_type,
        size_gb: size_gb,
        status: "creating"
      )

      provider_params = {
        name: volume.name,
        size_gb: size_gb,
        volume_type: volume_type&.name,
        availability_zone: options[:availability_zone],
        encrypted: options[:encrypted],
        kms_key_id: options[:kms_key_id],
        iops: options[:iops],
        throughput: options[:throughput]
      }.compact

      result = provider_adapter.create_volume(provider_params)

      if result[:success]
        volume.update!(cloud_volume_id: result[:volume_id], status: "available")
        Runtime::Result.ok(data: { volume: volume })
      else
        volume.update!(status: "failed")
        Runtime::Result.err(error: result[:error], data: { volume: volume })
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[VolumeManagementService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError
      raise
    rescue StandardError => e
      Rails.logger.error("[VolumeManagementService] Provision failed: #{e.message}")
      Runtime::Result.err(error: e.message)
    end

    def delete(volume:)
      validate_volume!(volume)

      unless volume.cloud_volume_id.present?
        volume.destroy!
        return Runtime::Result.ok
      end

      return Runtime::Result.err(error: "Volume is attached, detach first") if volume.provider_volume_members.any?

      Rails.logger.info("[VolumeManagementService] Deleting volume #{volume.name}")

      provider_adapter = begin
        Providers::Registry.for_volume(volume)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      result = provider_adapter.delete_volume(volume.cloud_volume_id)

      if result[:success]
        volume.destroy!
        Runtime::Result.ok
      else
        Runtime::Result.err(error: result[:error])
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[VolumeManagementService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError
      raise
    end

    def check(volume:)
      validate_volume!(volume)

      unless volume.cloud_volume_id.present?
        return Runtime::Result.ok(data: { status: volume.status, health: "unknown", message: "No cloud volume" })
      end

      Rails.logger.info("[VolumeManagementService] Checking volume #{volume.name}")

      provider_adapter = begin
        Providers::Registry.for_volume(volume)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      result = provider_adapter.get_volume(volume.cloud_volume_id)

      if result[:success]
        volume.update!(status: result[:status]) if result[:status] != volume.status

        Runtime::Result.ok(data: {
          status: result[:status],
          size_gb: result[:size_gb],
          volume_type: result[:volume_type],
          attached_to: result[:attached_to],
          device: result[:device]
        })
      else
        Runtime::Result.err(error: result[:error])
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[VolumeManagementService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError
      raise
    end

    private

    def validate_volume!(volume)
      raise ArgumentError, "Volume required" unless volume
      raise ArgumentError, "Volume must be a System::ProviderVolume" unless volume.is_a?(::System::ProviderVolume)
    end

    def validate_instance!(instance)
      raise ArgumentError, "Instance required" unless instance
      raise ArgumentError, "Instance must be a System::NodeInstance" unless instance.is_a?(::System::NodeInstance)
    end

    def validate_region!(region)
      raise ArgumentError, "Region required" unless region
      raise ArgumentError, "Region must be a System::ProviderRegion" unless region.is_a?(::System::ProviderRegion)
    end

    def next_available_device(instance)
      existing = ::System::ProviderVolumeMember.where(node_instance: instance).pluck(:device)

      ("b".."z").each do |letter|
        device = "/dev/sd#{letter}"
        return device unless existing.include?(device)
      end

      raise VolumeError, "No available device paths"
    end
  end
end
