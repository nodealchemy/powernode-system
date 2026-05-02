# frozen_string_literal: true

module System
  module Runtime
    # Deploys a System::NodeModule to a node or instance via
    # System::ModuleCommitService. Operable can be:
    #   System::NodeInstance  → commit to that instance
    #   System::Node          → commit to all running instances of the node
    #
    # Required operation.options:
    #   node_module_id - System::NodeModule id to commit
    class CommitModule
      def self.call(operation:)
        new(operation: operation).call
      end

      def initialize(operation:)
        @operation = operation
      end

      def call
        operable = @operation.operable
        opts = (@operation.options || {}).with_indifferent_access
        node_module_id = opts[:node_module_id]

        if node_module_id.blank?
          return Result.err(error: "Missing required option: node_module_id")
        end

        node_module = ::System::NodeModule.find_by(id: node_module_id)
        unless node_module
          return Result.err(error: "NodeModule #{node_module_id} not found")
        end

        @operation.update_progress!(10, "Starting module commit")

        result =
          case operable
          when ::System::NodeInstance
            ::System::ModuleCommitService.commit(
              node_module: node_module,
              instance: operable,
              options: opts.except(:node_module_id).to_h
            )
          when ::System::Node
            ::System::ModuleCommitService.commit_to_node(
              node_module: node_module,
              node: operable,
              options: opts.except(:node_module_id).to_h
            )
          else
            return Result.err(
              error: "Cannot commit module to operable of type #{operable&.class&.name || 'nil'}"
            )
          end

        @operation.update_progress!(90, "Module commit returned")

        result
      rescue StandardError => e
        Result.err(
          error: "Exception during module commit: #{e.message}",
          data: { exception: e.class.name, backtrace: Array(e.backtrace).first(10) }
        )
      end
    end
  end
end
