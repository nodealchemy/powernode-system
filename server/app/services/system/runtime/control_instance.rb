# frozen_string_literal: true

module System
  module Runtime
    # Executes lifecycle actions on a System::NodeInstance via
    # System::InstanceControlService. The operation.command maps to the
    # action InstanceControlService actually understands: "restart" and
    # "reboot" both drive the "reboot" action. "deprovision" and "terminate"
    # were both mapped here once and BOTH are retired — deprovision with the
    # thirteen zero-caller verbs, terminate in campaign 01a0790b increment 2
    # (the agent answers it with `systemctl reboot`, so destroying an instance
    # belongs to System::Executors::TerminateInstance).
    #
    # Operation.operable must be a System::NodeInstance.
    class ControlInstance
      # `deprovision` was mapped here as an alias for terminate and is gone: it
      # was retired from ExecutionDispatcher::COMMAND_REGISTRY (no producer,
      # literal or variable, and zero rows in the table's lifetime), and
      # System::Task now VALIDATES command against COMMANDS — so no task can
      # carry it and this arm was unreachable.
      # "terminate" LEFT this map in campaign 01a0790b increment 2, with the
      # command itself: it is gone from System::Task::COMMANDS and from
      # COMMAND_REGISTRY, so no Task the model will now create can name it.
      # An in-flight legacy terminate row still transitions (the COMMANDS
      # validation is guarded on command_changed?), but it has no server-side
      # runtime to reach and the agent answers it with `systemctl reboot`.
      #
      # "restart" is kept, and it is NOT unreachable — an earlier draft of this
      # comment said "unreachable by construction" and was wrong.
      # ExecutionDispatcher.restart_scope falls THROUGH to inference when the
      # declared scope is not in RESTART_SCOPES, and a bare `{}` / nil / a
      # legacy `{"scope"=>"instance"}` all infer "instance" — so
      # agent_delegated? is false and this class still reboots the VM through
      # the provider.
      #
      # What actually stops a NEW row taking that path is the MODEL validation
      # (System::Task#restart_scope_declared), and that is guarded on
      # will_save_change_to_command?/options?, so legacy rows, update_columns
      # and save(validate: false) all bypass it. restart_scope's own header
      # says pre-declaration rows are still in flight. Campaign increment 3
      # retires this dispatch path, which is what finally closes it.
      ACTION_FOR_COMMAND = {
        "start" => "start",
        "stop" => "stop",
        "restart" => "reboot",
        "reboot" => "reboot"
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
