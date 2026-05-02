# frozen_string_literal: true

module System
  module Runtime
    # Attaches a System::ProviderVolume to a System::NodeInstance via
    # System::VolumeManagementService. Operable is the volume.
    #
    # Required operation.options:
    #   instance_id - System::NodeInstance id to attach to
    # Optional operation.options:
    #   device      - device name hint (e.g., "/dev/xvdf")
    class AttachVolume
      def self.call(operation:)
        new(operation: operation).call
      end

      def initialize(operation:)
        @operation = operation
      end

      def call
        volume = @operation.operable
        unless volume.is_a?(::System::ProviderVolume)
          return Result.err(
            error: "Operation operable must be System::ProviderVolume (got #{volume&.class&.name || 'nil'})"
          )
        end

        opts = (@operation.options || {}).with_indifferent_access
        instance_id = opts[:instance_id]
        if instance_id.blank?
          return Result.err(error: "Missing required option: instance_id")
        end

        instance = ::System::NodeInstance.find_by(id: instance_id)
        unless instance
          return Result.err(error: "NodeInstance #{instance_id} not found")
        end

        @operation.update_progress!(20, "Attaching volume #{volume.id} to instance #{instance.id}")

        result = ::System::VolumeManagementService.attach(
          volume: volume,
          instance: instance,
          device: opts[:device]
        )

        @operation.update_progress!(90, "Attach returned")

        result
      rescue StandardError => e
        Result.err(
          error: "Exception during volume attach: #{e.message}",
          data: { exception: e.class.name, backtrace: Array(e.backtrace).first(10) }
        )
      end
    end
  end
end
