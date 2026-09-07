# frozen_string_literal: true

module System
  # Synchronizes cloud instance state with the underlying cloud provider.
  # Public methods return System::Runtime::Result. Provider adapters below
  # this layer keep their cloud-shape hash; this service is the boundary
  # that maps that into the platform-standard Result.
  class CloudSyncService
    class SyncError < StandardError; end

    # IMP-555e29eeb4ab: grace period before a local instance absent from the
    # cloud listing is presumed deleted out-of-band. A NodeInstance can be
    # assigned its cloud_instance_id immediately after provisioning, before
    # the provider's list API is guaranteed to reflect it yet (eventual
    # consistency) — without this window, a brand-new, genuinely-running
    # instance synced in that narrow gap would be force-terminated.
    TERMINATION_SWEEP_GRACE_SECONDS = (ENV["CLOUD_SYNC_TERMINATION_GRACE_SECONDS"] || 900).to_i

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
          # Recorded OUTSIDE the `updated` branch: it is what the provider last
          # reported, so a healthy row whose state did not change must still get
          # a fresh observation. Inside the branch it would only ever be written
          # for rows that changed — the opposite of the column's contract, and
          # it would leave a refused row as the best-observed row on the fleet.
          instance.record_provider_power_state!(data[:status])

          if data[:updated]
            update_data = { last_synced_at: Time.current }
            # IMP-231f17d71dfa. This is a BARE update!, not an AASM event, so no
            # may_X? guard on the model's transitions applies to it — and per the
            # comment on the termination sweep below, this method is the path the
            # scheduled hourly SystemCloudSyncJob actually takes. It was therefore
            # the real producer of the observed flap: six instances, several
            # silent for weeks, re-described as running once an hour because the
            # hypervisor still had their VMs powered on.
            #
            # Omitting the key leaves the existing status untouched rather than
            # writing something else, so a refusal here is inert, never a
            # competing verdict. The IP and last_synced_at updates still land:
            # declining to believe the power state says nothing about the address
            # the provider reports.
            if instance.provider_state_may_promote?(data[:status])
              update_data[:status] = data[:status]
            end
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

      # Capability gate (F4-06) — pro_cloud has no region-wide listing.
      unless provider_adapter.supports?(:sync)
        return Runtime::Result.err(error: "Provider #{provider_adapter.provider_type} does not support instance sync (list_instances)")
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

      # cloud_instance_id is a store_accessor on the config JSONB column, not
      # a real table column — `.where.not(cloud_instance_id: nil)` raised
      # PG::UndefinedColumn on every real invocation (never caught: the only
      # spec/request-spec coverage of this method fully mocked
      # CloudSyncService, so the raw query was never exercised against a DB).
      local_instances = ::System::NodeInstance
        .where(provider_region: region)
        .where(variety: %w[cloud dynamic])
        .where("config ->> 'cloud_instance_id' IS NOT NULL")
        .index_by(&:cloud_instance_id)

      synced_count = 0
      updated_count = 0
      # Rows whose provider-reported status was deliberately not applied — see
      # the guard below. Reported alongside updated_count so "nothing changed"
      # and "we refused to change it" are never the same number.
      held_count = 0
      seen_cloud_instance_ids = Set.new

      cloud_instances.each do |cloud_data|
        seen_cloud_instance_ids << cloud_data[:cloud_instance_id]
        local_instance = local_instances[cloud_data[:cloud_instance_id]]
        next unless local_instance

        local_instance.record_provider_power_state!(cloud_data[:status])

        if state_changed?(local_instance, cloud_data)
          # IMP-231f17d71dfa — THIS is the write the hourly SystemCloudSyncJob
          # performs, and it is a bare update! with no AASM event, so none of the
          # may_X? guards on the model's transitions are consulted. It was the
          # real producer of the observed flap: six instances, several silent for
          # weeks, re-described as running once an hour because their VMs were
          # still powered on at the hypervisor. A guard on the controllers' AASM
          # events alone would not have touched this line.
          #
          # Omitting the key leaves the existing status untouched rather than
          # writing a competing one, so a refusal is inert AS A WRITE. The IPs and
          # last_synced_at still land: declining to believe the power state says
          # nothing about the address the provider reports.
          #
          # A refusal must not be inert as a FACT, though. state_changed? below
          # compares status, so a refused row reports "changed" on every sweep
          # forever — the disagreement between provider and platform is permanent
          # by design, that being the point. Counted and logged separately so the
          # hourly summary does not report a held row as an update that landed,
          # and so a standing refusal is visible rather than inferred from a
          # count that never falls.
          attrs = {
            private_ip_address: cloud_data[:private_ip_address],
            public_ip_address: cloud_data[:public_ip_address],
            last_synced_at: Time.current
          }
          if local_instance.provider_state_may_promote?(cloud_data[:status])
            attrs[:status] = cloud_data[:status]
            updated_count += 1
          else
            held_count += 1
            Rails.logger.info(
              "[CloudSyncService] held provider status for instance=#{local_instance.id}: " \
              "provider reports #{cloud_data[:status]}, platform holds #{local_instance.status} " \
              "(presumed dead #{local_instance.presumed_dead_at&.iso8601}, " \
              "last heartbeat #{local_instance.last_heartbeat_at&.iso8601})"
            )
          end
          local_instance.update!(attrs)
        else
          local_instance.update!(last_synced_at: Time.current)
        end
        synced_count += 1
      end

      # A local row whose cloud_instance_id never showed up in the listing
      # was deleted out-of-band — the provider has no record of it at all,
      # distinct from a stopped/errored instance the listing still reports.
      # Mirrors the NotFound->terminated branch in sync_instance_state,
      # which only runs on the per-instance path nothing schedules; this is
      # the actual hourly scheduled sweep (SystemCloudSyncJob ->
      # sync_region_instances), so it's the only path that ever reconciles a
      # deleted instance. Skipped when the listing was truncated — an unseen
      # page, not a deletion, would otherwise be misread as "gone". Goes
      # through the AASM `terminate!` event (legal from any non-terminal
      # state) rather than a raw status write, so the transition is audited
      # (System::LifecycleAuditable) the same as every other real status
      # change on this model.
      terminated_count = 0
      unless truncated
        local_instances.each do |cloud_instance_id, local_instance|
          next if seen_cloud_instance_ids.include?(cloud_instance_id)
          next if local_instance.status == "terminated"
          next if local_instance.created_at > TERMINATION_SWEEP_GRACE_SECONDS.seconds.ago
          next unless local_instance.may_terminate?

          local_instance.terminate!
          local_instance.update!(last_synced_at: Time.current)
          terminated_count += 1
          updated_count += 1
          synced_count += 1
        end
      end

      Runtime::Result.ok(data: {
        synced_count: synced_count,
        updated_count: updated_count,
        # IMP-231f17d71dfa: rows whose provider status was deliberately held.
        # Reported so the hourly summary distinguishes "the platform agrees with
        # the provider" from "the platform is refusing the provider's verdict";
        # a non-zero, non-falling held_count is the signal that instances are
        # sitting presumed-dead with their VMs still powered on.
        held_count: held_count,
        terminated_count: terminated_count,
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
