# frozen_string_literal: true

module System
  module Runtime
    # Builds a System::NodeModule into distributable artifacts via
    # System::ModuleBuildService. The build is multi-stage; progress is
    # reported to the operation's events log throughout.
    #
    # Operation.operable must be a System::NodeModule.
    class BuildModule
      def self.call(operation:)
        new(operation: operation).call
      end

      def initialize(operation:)
        @operation = operation
      end

      def call
        node_module = @operation.operable
        unless node_module.is_a?(::System::NodeModule)
          return Result.err(
            error: "Operation operable must be System::NodeModule (got #{node_module&.class&.name || 'nil'})"
          )
        end

        @operation.update_progress!(10, "Starting module build")

        result = ::System::ModuleBuildService.build(
          node_module: node_module,
          options: (@operation.options || {})
        )

        @operation.update_progress!(90, "Module build returned")

        result
      rescue StandardError => e
        Result.err(
          error: "Exception during module build: #{e.message}",
          data: { exception: e.class.name, backtrace: Array(e.backtrace).first(10) }
        )
      end
    end
  end
end
