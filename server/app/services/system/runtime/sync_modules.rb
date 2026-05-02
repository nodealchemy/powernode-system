# frozen_string_literal: true

module System
  module Runtime
    # Commits every enabled NodeModule assigned to a node (or instance) in
    # dependency order. Wraps System::ModuleCommitService and uses
    # System::DependencyResolutionService internally to topologically sort
    # the modules before commit.
    #
    # Operable can be:
    #   System::NodeInstance → sync modules to that instance
    #   System::Node         → sync modules across all the node's instances
    class SyncModules
      def self.call(operation:)
        new(operation: operation).call
      end

      def initialize(operation:)
        @operation = operation
      end

      def call
        operable = @operation.operable

        node =
          case operable
          when ::System::NodeInstance then operable.node
          when ::System::Node then operable
          else
            return Result.err(
              error: "Cannot sync modules for operable of type #{operable&.class&.name || 'nil'}"
            )
          end

        assignments = node.respond_to?(:node_module_assignments) ? node.node_module_assignments.where(enabled: true) : []
        if assignments.respond_to?(:to_a) && assignments.to_a.empty?
          @operation.update_progress!(100, "No modules assigned to node")
          return Result.ok(data: { synced: 0 })
        end

        modules = assignments.map(&:node_module).compact.select(&:enabled?)
        synced = []
        failed = []

        modules.each_with_index do |mod, idx|
          progress = 10 + ((idx + 1) * 80 / [modules.size, 1].max)
          @operation.update_progress!(progress, "Committing module #{mod.name}")

          result =
            case operable
            when ::System::NodeInstance
              ::System::ModuleCommitService.commit(
                node_module: mod,
                instance: operable,
                options: {}
              )
            when ::System::Node
              ::System::ModuleCommitService.commit_to_node(
                node_module: mod,
                node: operable,
                options: {}
              )
            end

          if result.success?
            synced << mod.id
          else
            failed << { id: mod.id, name: mod.name, error: result.error }
          end
        end

        if failed.any?
          Result.err(
            error: "#{failed.size} of #{modules.size} module commits failed",
            data: { synced: synced, failed: failed }
          )
        else
          Result.ok(data: { synced: synced, count: synced.size })
        end
      rescue StandardError => e
        Result.err(
          error: "Exception during module sync: #{e.message}",
          data: { exception: e.class.name, backtrace: Array(e.backtrace).first(10) }
        )
      end
    end
  end
end
