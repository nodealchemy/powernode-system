# frozen_string_literal: true

module System
  module Runtime
    # Detaches a System::ProviderVolume from its current instance via
    # System::VolumeManagementService. Operable is the volume.
    #
    # Optional operation.options:
    #   force - boolean to force detach even if instance is running
    class DetachVolume
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

        force = (@operation.options || {})["force"] == true

        @operation.update_progress!(20, "Detaching volume #{volume.id}")

        result = ::System::VolumeManagementService.detach(volume: volume, force: force)

        @operation.update_progress!(90, "Detach returned")

        result
      rescue StandardError => e
        Result.err(
          error: "Exception during volume detach: #{e.message}",
          data: { exception: e.class.name, backtrace: Array(e.backtrace).first(10) }
        )
      end
    end
  end
end
