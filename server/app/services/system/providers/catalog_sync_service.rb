# frozen_string_literal: true

module System
  module Providers
    # Imports a cloud provider's catalog (regions, availability zones,
    # instance types, volume types) into the platform's catalog tables for
    # one ProviderConnection. Idempotent: re-running upserts and never
    # destroys rows that may have downstream references.
    #
    # Triggered by:
    #   - POST /api/v1/system/provider_connections/:id/sync_catalog
    #     (operator-initiated, runs synchronously)
    #
    # Scoping:
    #   - Regions, instance types, volume types live per Provider × Account
    #   - Availability zones live per Region (no separate account scope)
    #
    # Returns a Runtime::Result with per-resource upsert counts on success.
    class CatalogSyncService
      def self.sync_for(connection)
        new(connection).sync
      end

      def initialize(connection)
        @connection = connection
        @account = connection.account
        @provider = connection.provider
      end

      def sync
        adapter = Registry.for(@connection)

        regions_summary = sync_regions(adapter)
        zones_summary = sync_zones(adapter, regions_summary[:imported])
        instance_types_summary = sync_instance_types(adapter, regions_summary[:imported])
        volume_types_summary = sync_volume_types(adapter)

        @connection.update!(last_tested_at: Time.current)

        Runtime::Result.ok(data: {
          regions: regions_summary[:counts],
          availability_zones: zones_summary,
          instance_types: instance_types_summary,
          volume_types: volume_types_summary
        })
      rescue Registry::UnknownProviderError => e
        Runtime::Result.err(error: "Provider resolution failed: #{e.message}")
      rescue StandardError => e
        Rails.logger.error("[CatalogSyncService] #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
        Runtime::Result.err(
          error: "Catalog sync failed: #{e.message}",
          data: { exception: e.class.name }
        )
      end

      private

      def sync_regions(adapter)
        rows = Array(adapter.list_regions)
        created = updated = 0
        imported = []

        rows.each do |r|
          region = ::System::ProviderRegion.find_or_initialize_by(
            account_id: @account.id,
            provider_id: @provider.id,
            region_code: r[:cloud_id]
          )
          attrs = {
            name: r[:name] || r[:cloud_id],
            description: r[:description],
            enabled: true,
            capabilities: r.except(:cloud_id, :name, :description).stringify_keys
          }.compact

          if region.new_record?
            region.assign_attributes(attrs)
            region.save!
            created += 1
          elsif attrs_differ?(region, attrs)
            region.update!(attrs)
            updated += 1
          end

          imported << region
        end

        { counts: { created: created, updated: updated, total: rows.size }, imported: imported }
      end

      def sync_zones(adapter, regions)
        created = updated = 0
        regions.each do |region|
          rows = Array(adapter.list_availability_zones(region.region_code))
          rows.each do |z|
            zone = ::System::ProviderAvailabilityZone.find_or_initialize_by(
              provider_region_id: region.id,
              zone_code: z[:cloud_id]
            )
            attrs = {
              name: z[:name] || z[:cloud_id],
              status: z[:status] || "available",
              enabled: true,
              capabilities: z.except(:cloud_id, :name, :status).stringify_keys
            }.compact

            if zone.new_record?
              zone.assign_attributes(attrs)
              zone.save!
              created += 1
            elsif attrs_differ?(zone, attrs)
              zone.update!(attrs)
              updated += 1
            end
          end
        end
        { created: created, updated: updated }
      end

      def sync_instance_types(adapter, regions)
        # Many cloud providers expose instance-type catalog per-region. Some
        # (Azure) return per-region SKUs; others (AWS) have a global catalog.
        # We dedupe by instance_type_code at the (account, provider) tuple.
        seen = {}
        regions.each do |region|
          rows = Array(adapter.list_instance_types(region.region_code))
          rows.each do |t|
            seen[t[:cloud_id]] ||= t
          end
        end

        created = updated = 0
        seen.each do |code, t|
          instance_type = ::System::ProviderInstanceType.find_or_initialize_by(
            account_id: @account.id,
            provider_id: @provider.id,
            instance_type_code: code
          )
          attrs = {
            name: t[:name] || code,
            description: t[:description],
            vcpus: t[:vcpus],
            memory_mb: t[:memory_gb] ? (t[:memory_gb] * 1024).to_i : t[:memory_mb],
            storage_gb: t[:storage_gb],
            processor_type: t[:family] || t[:processor_type]
          }.compact

          if instance_type.new_record?
            instance_type.assign_attributes(attrs)
            instance_type.save!
            created += 1
          elsif attrs_differ?(instance_type, attrs)
            instance_type.update!(attrs)
            updated += 1
          end
        end

        { created: created, updated: updated, total: seen.size }
      end

      def sync_volume_types(adapter)
        # Volume types are typically a small fixed list per cloud (Azure:
        # platform-defined SKUs; AWS: gp3/gp2/io1/io2/st1/sc1; OpenStack:
        # operator-defined). list_volume_types takes a region but returns
        # the canonical set; we sync once.
        rows = Array(adapter.list_volume_types(nil))
        created = updated = 0

        rows.each do |v|
          vt = ::System::ProviderVolumeType.find_or_initialize_by(
            account_id: @account.id,
            provider_id: @provider.id,
            volume_type: v[:cloud_id]
          )
          attrs = {
            name: v[:name] || v[:cloud_id],
            description: v[:description],
            min_size_gb: v[:min_size_gb] || 1,
            max_size_gb: v[:max_size_gb] || 16_384,
            min_iops: v[:min_iops] || v[:iops],
            max_iops: v[:max_iops] || v[:iops],
            min_throughput: v[:min_throughput] || v[:throughput_mbps],
            max_throughput: v[:max_throughput] || v[:throughput_mbps],
            enabled: true,
            specs: v.except(:cloud_id, :name, :description, :min_size_gb, :max_size_gb,
                            :min_iops, :max_iops, :min_throughput, :max_throughput,
                            :iops, :throughput_mbps).stringify_keys
          }.compact

          if vt.new_record?
            vt.assign_attributes(attrs)
            vt.save!
            created += 1
          elsif attrs_differ?(vt, attrs)
            vt.update!(attrs)
            updated += 1
          end
        end

        { created: created, updated: updated, total: rows.size }
      end

      # Compare candidate attrs against the record's current values. We only
      # write if there's a real change so updated_at and after_commit
      # broadcasts don't fire for noop syncs.
      def attrs_differ?(record, attrs)
        attrs.any? { |k, v| record.public_send(k) != v }
      end
    end
  end
end
