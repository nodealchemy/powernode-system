# frozen_string_literal: true

module System
  # Synchronizes cloud instance state with the underlying cloud provider.
  # Public methods return System::Runtime::Result. Provider adapters below
  # this layer keep their cloud-shape hash; this service is the boundary
  # that maps that into the platform-standard Result.
  class CloudSyncService
    class SyncError < StandardError; end

    def self.sync_instance_state(instance:)
      new.sync_instance_state(instance: instance)
    end

    def self.sync_node_instances(node:)
      new.sync_node_instances(node: node)
    end

    def self.sync_region_instances(region:, account:)
      new.sync_region_instances(region: region, account: account)
    end

    def sync_instance_state(instance:)
      validate_instance!(instance)

      unless %w[cloud dynamic].include?(instance.variety)
        return Runtime::Result.err(error: "Instance variety #{instance.variety} does not support cloud sync")
      end

      return Runtime::Result.err(error: "Instance has no cloud instance ID") unless instance.cloud_instance_id.present?

      Rails.logger.info("[CloudSyncService] Syncing instance #{instance.name}")

      provider_adapter = begin
        Providers::Registry.for_instance(instance)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      result = provider_adapter.get_instance(instance.cloud_instance_id)

      if result[:success]
        Runtime::Result.ok(data: {
          status: result[:status],
          private_ip_address: result[:private_ip_address],
          public_ip_address: result[:public_ip_address],
          instance_type: result[:instance_type],
          updated: state_changed?(instance, result)
        })
      elsif result[:error_code] == "NotFound"
        terminated_result(instance)
      else
        Runtime::Result.err(error: result[:error])
      end
    rescue Providers::BaseProvider::ResourceNotFoundError
      terminated_result(instance)
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[CloudSyncService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError
      raise
    rescue StandardError => e
      Rails.logger.error("[CloudSyncService] Sync failed: #{e.message}")
      Runtime::Result.err(error: e.message)
    end

    def sync_node_instances(node:)
      validate_node!(node)

      instances = node.node_instances.where(variety: %w[cloud dynamic])
      synced_count = 0
      errors = []

      instances.find_each do |instance|
        result = sync_instance_state(instance: instance)

        if result.success?
          data = result.data
          if data[:updated]
            update_data = { status: data[:status], last_synced_at: Time.current }
            update_data[:private_ip_address] = data[:private_ip_address] if data.key?(:private_ip_address)
            update_data[:public_ip_address]  = data[:public_ip_address]  if data.key?(:public_ip_address)
            instance.update!(update_data)
          else
            instance.update!(last_synced_at: Time.current)
          end
          synced_count += 1
        else
          errors << { instance_id: instance.id, error: result.error }
        end
      end

      data = { synced_count: synced_count, total_count: instances.count, errors: errors }
      errors.empty? ? Runtime::Result.ok(data: data) : Runtime::Result.err(error: "#{errors.size} instance(s) failed to sync", data: data)
    end

    def sync_region_instances(region:, account:)
      validate_region!(region)

      connection = Providers::Registry.find_connection_for_region(region, account)
      return Runtime::Result.err(error: "No provider connection available") unless connection

      provider_adapter = begin
        Providers::Registry.for(connection, region: region)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      cloud_result = provider_adapter.list_instances
      return Runtime::Result.err(error: cloud_result[:error]) unless cloud_result[:success]

      cloud_instances = cloud_result[:instances] || []
      page_count = cloud_result[:page_count].to_i
      truncated  = cloud_result[:truncated] == true

      if truncated
        Rails.logger.warn(
          "[CloudSyncService] list_instances truncated at #{page_count} pages " \
          "(#{cloud_instances.size} instances) for region=#{region.id} provider=#{connection.provider_id} — " \
          "raise :max_pages or page through manually if more remain"
        )
      end

      local_instances = ::System::NodeInstance
        .where(provider_region: region)
        .where(variety: %w[cloud dynamic])
        .where.not(cloud_instance_id: nil)
        .index_by(&:cloud_instance_id)

      synced_count = 0
      updated_count = 0

      cloud_instances.each do |cloud_data|
        local_instance = local_instances[cloud_data[:cloud_instance_id]]
        next unless local_instance

        if state_changed?(local_instance, cloud_data)
          local_instance.update!(
            status: cloud_data[:status],
            private_ip_address: cloud_data[:private_ip_address],
            public_ip_address: cloud_data[:public_ip_address],
            last_synced_at: Time.current
          )
          updated_count += 1
        else
          local_instance.update!(last_synced_at: Time.current)
        end
        synced_count += 1
      end

      Runtime::Result.ok(data: {
        synced_count: synced_count,
        updated_count: updated_count,
        cloud_count: cloud_instances.size,
        page_count: page_count,
        truncated: truncated
      })
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[CloudSyncService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError
      raise
    end

    private

    def terminated_result(instance)
      Runtime::Result.ok(data: {
        status: "terminated",
        private_ip_address: nil,
        public_ip_address: nil,
        updated: instance.status != "terminated"
      })
    end

    def validate_instance!(instance)
      raise ArgumentError, "Instance required" unless instance
      raise ArgumentError, "Instance must be a System::NodeInstance" unless instance.is_a?(::System::NodeInstance)
    end

    def validate_node!(node)
      raise ArgumentError, "Node required" unless node
      raise ArgumentError, "Node must be a System::Node" unless node.is_a?(::System::Node)
    end

    def validate_region!(region)
      raise ArgumentError, "Region required" unless region
      raise ArgumentError, "Region must be a System::ProviderRegion" unless region.is_a?(::System::ProviderRegion)
    end

    def state_changed?(instance, result)
      instance.status != result[:status] ||
        instance.private_ip_address != result[:private_ip_address] ||
        instance.public_ip_address != result[:public_ip_address]
    end
  end
end
