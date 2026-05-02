# frozen_string_literal: true

module System
  module Runtime
    # Runs an arbitrary shell command on a System::NodeInstance via
    # System::SshExecutionService. Operable is the instance.
    #
    # Required operation.options:
    #   command - shell command string to execute
    # Optional operation.options:
    #   sudo - boolean (default true)
    class ExecuteSshCommand
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

        opts = (@operation.options || {}).with_indifferent_access
        command = opts[:command]
        if command.blank?
          return Result.err(error: "Missing required option: command")
        end

        sudo = opts.key?(:sudo) ? !!opts[:sudo] : true

        @operation.update_progress!(20, "Executing SSH command")

        result = ::System::SshExecutionService.execute(
          instance: instance,
          command: command,
          sudo: sudo,
          operation_id: @operation.id
        )

        @operation.update_progress!(90, "SSH command returned")

        result
      rescue StandardError => e
        Result.err(
          error: "Exception during SSH execute: #{e.message}",
          data: { exception: e.class.name, backtrace: Array(e.backtrace).first(10) }
        )
      end
    end
  end
end
