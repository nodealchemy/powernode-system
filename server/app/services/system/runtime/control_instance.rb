# frozen_string_literal: true

module System
  module Runtime
    # Executes lifecycle actions on a System::NodeInstance via
    # System::InstanceControlService. The operation.command maps to the
    # action: "start", "stop", "restart"/"reboot", "terminate", etc.
    #
    # Operation.operable must be a System::NodeInstance.
    class ControlInstance
      ACTION_FOR_COMMAND = {
        "start" => "start",
        "stop" => "stop",
        "restart" => "restart",
        "reboot" => "restart",
        "terminate" => "terminate"
      }.freeze

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

        action = ACTION_FOR_COMMAND[@operation.command]
        unless action
          return Result.err(error: "Unsupported control command: #{@operation.command}")
        end

        force = (@operation.options || {})["force"] == true

        @operation.update_progress!(20, "Calling InstanceControlService #{action}")

        result = ::System::InstanceControlService.execute(
          instance: instance,
          action: action,
          operation_id: @operation.id,
          force: force
        )

        @operation.update_progress!(90, "Control action returned")
        result
      rescue StandardError => e
        Result.err(
          error: "Exception during control: #{e.message}",
          data: { exception: e.class.name, backtrace: Array(e.backtrace).first(10) }
        )
      end
    end
  end
end
