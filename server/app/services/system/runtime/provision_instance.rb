# frozen_string_literal: true

module System
  module Runtime
    # Provisions a cloud instance for a System::Node. Wraps the core
    # System::ProvisioningService.provision_instance entry point.
    #
    # Required operation.options:
    #   provider_region_id        - System::ProviderRegion id
    #   provider_instance_type_id - System::ProviderInstanceType id
    # Optional operation.options:
    #   any other keys accepted by ProvisioningService (passed through)
    class ProvisionInstance
      def self.call(operation:)
        new(operation: operation).call
      end

      def initialize(operation:)
        @operation = operation
      end

      def call
        node = @operation.operable
        unless node.is_a?(::System::Node)
          return Result.err(
            error: "Operation operable must be System::Node (got #{node&.class&.name || 'nil'})"
          )
        end

        opts = (@operation.options || {}).with_indifferent_access
        region_id = opts[:provider_region_id]
        instance_type_id = opts[:provider_instance_type_id]

        if region_id.blank? || instance_type_id.blank?
          return Result.err(
            error: "Missing required options: provider_region_id, provider_instance_type_id"
          )
        end

        @operation.update_progress!(10, "Resolving provider connection")

        result = ::System::ProvisioningService.provision_instance(
          node: node,
          provider_region_id: region_id,
          provider_instance_type_id: instance_type_id,
          operation_id: @operation.id,
          options: opts.except(:provider_region_id, :provider_instance_type_id).to_h
        )

        @operation.update_progress!(90, "Provisioning step returned")

        result
      rescue StandardError => e
        Result.err(
          error: "Exception during provisioning: #{e.message}",
          data: { exception: e.class.name, backtrace: Array(e.backtrace).first(10) }
        )
      end
    end
  end
end
