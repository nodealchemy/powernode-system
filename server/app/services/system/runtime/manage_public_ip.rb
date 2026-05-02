# frozen_string_literal: true

module System
  module Runtime
    # Allocates+associates a public IP, or disassociates+releases one,
    # against the cloud provider for the operation's NodeInstance.
    #
    # Two commands map here:
    #   - "associate_public_ip"    → allocate_ip → associate_ip → persist
    #   - "disassociate_public_ip" → disassociate_ip → release_ip → clear
    #
    # The allocation_id and association_id returned by the provider are
    # cached in `instance.config` so the disassociate path can release the
    # exact resource that was allocated. Without this round-trip identity,
    # we'd leak elastic IPs on every association cycle.
    class ManagePublicIp
      ASSOCIATE_KEY    = "public_ip_allocation_id"
      ASSOCIATION_KEY  = "public_ip_association_id"

      def self.call(operation:)
        new(operation: operation).call
      end

      def initialize(operation:)
        @operation = operation
      end

      def call
        instance = @operation.operable
        unless instance.is_a?(::System::NodeInstance)
          return Result.err(
            error: "Operation operable must be System::NodeInstance (got #{instance&.class&.name || 'nil'})"
          )
        end

        unless instance.cloud?
          return Result.err(error: "Public IP management requires a cloud instance")
        end

        adapter = ::System::Providers::Registry.for_instance(instance)

        case @operation.command
        when "associate_public_ip"   then associate(instance, adapter)
        when "disassociate_public_ip" then disassociate(instance, adapter)
        else
          Result.err(error: "Unsupported public IP command: #{@operation.command}")
        end
      rescue ::System::Providers::Registry::UnknownProviderError => e
        Result.err(error: "Provider resolution failed: #{e.message}")
      rescue StandardError => e
        Result.err(
          error: "Exception during IP management: #{e.message}",
          data: { exception: e.class.name, backtrace: Array(e.backtrace).first(10) }
        )
      end

      private

      def associate(instance, adapter)
        cloud_instance_id = instance.config&.dig("cloud_instance_id")
        unless cloud_instance_id.present?
          return Result.err(error: "Instance has no cloud_instance_id; cannot associate public IP")
        end

        @operation.update_progress!(20, "Allocating public IP")
        alloc = adapter.allocate_ip
        unless alloc[:success]
          return Result.err(error: alloc[:error] || "allocate_ip failed", data: alloc)
        end

        @operation.update_progress!(60, "Associating IP #{alloc[:public_ip]}")
        assoc = adapter.associate_ip(cloud_instance_id, allocation_id: alloc[:allocation_id])
        unless assoc[:success]
          # Best-effort release on partial failure.
          adapter.release_ip(alloc[:allocation_id]) rescue nil
          return Result.err(error: assoc[:error] || "associate_ip failed", data: assoc)
        end

        instance.public_ip_address = assoc[:public_ip] || alloc[:public_ip]
        new_config = (instance.config || {}).merge(
          ASSOCIATE_KEY   => alloc[:allocation_id],
          ASSOCIATION_KEY => assoc[:association_id]
        )
        instance.update!(config: new_config)

        @operation.update_progress!(95, "Public IP associated")
        Result.ok(data: { public_ip: instance.public_ip_address, allocation_id: alloc[:allocation_id] })
      end

      def disassociate(instance, adapter)
        association_id = instance.config&.dig(ASSOCIATION_KEY)
        allocation_id  = instance.config&.dig(ASSOCIATE_KEY)

        if association_id.blank? && allocation_id.blank?
          return Result.err(error: "Instance has no recorded public IP allocation/association IDs")
        end

        if association_id.present?
          @operation.update_progress!(30, "Disassociating IP")
          disassoc = adapter.disassociate_ip(association_id)
          unless disassoc[:success]
            return Result.err(error: disassoc[:error] || "disassociate_ip failed", data: disassoc)
          end
        end

        if allocation_id.present?
          @operation.update_progress!(70, "Releasing IP allocation")
          release = adapter.release_ip(allocation_id)
          unless release[:success]
            # IP is already disassociated — surface the error but don't roll back
            return Result.err(error: release[:error] || "release_ip failed", data: release)
          end
        end

        new_config = (instance.config || {}).except(ASSOCIATE_KEY, ASSOCIATION_KEY)
        instance.update!(public_ip_address: nil, config: new_config)

        @operation.update_progress!(95, "Public IP released")
        Result.ok(data: { released: true })
      end
    end
  end
end
