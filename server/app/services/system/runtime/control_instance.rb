# frozen_string_literal: true

module System
  module Runtime
    # Executes lifecycle actions on a System::NodeInstance via
    # System::InstanceControlService. The operation.command maps to the
    # action InstanceControlService actually understands: "restart" and
    # "reboot" both drive the "reboot" action; "deprovision" is an alias
    # for "terminate" (see ExecutionDispatcher::COMMAND_REGISTRY).
    #
    # Operation.operable must be a System::NodeInstance.
    class ControlInstance
      # `deprovision` was mapped here as an alias for terminate and is gone: it
      # was retired from ExecutionDispatcher::COMMAND_REGISTRY (no producer,
      # literal or variable, and zero rows in the table's lifetime), and
      # System::Task now VALIDATES command against COMMANDS — so no task can
      # carry it and this arm was unreachable.
      ACTION_FOR_COMMAND = {
        "start" => "start",
        "stop" => "stop",
        "restart" => "reboot",
        "reboot" => "reboot",
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
