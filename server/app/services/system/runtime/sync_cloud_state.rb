# frozen_string_literal: true

module System
  module Runtime
    # Reconciles platform's recorded state with the cloud provider's
    # actual state for an instance, node, or region. Wraps the matching
    # System::CloudSyncService entry point depending on operable type.
    class SyncCloudState
      def self.call(operation:)
        new(operation: operation).call
      end

      def initialize(operation:)
        @operation = operation
      end

      def call
        operable = @operation.operable

        @operation.update_progress!(10, "Starting cloud state sync")

        result =
          case operable
          when ::System::NodeInstance
            ::System::CloudSyncService.sync_instance_state(instance: operable)
          when ::System::Node
            ::System::CloudSyncService.sync_node_instances(node: operable)
          when ::System::ProviderRegion
            account = @operation.account
            ::System::CloudSyncService.sync_region_instances(region: operable, account: account)
          else
            return Result.err(
              error: "Cannot sync operable of type #{operable&.class&.name || 'nil'}"
            )
          end

        @operation.update_progress!(90, "Cloud sync returned")

        result
      rescue StandardError => e
        Result.err(
          error: "Exception during cloud sync: #{e.message}",
          data: { exception: e.class.name, backtrace: Array(e.backtrace).first(10) }
        )
      end
    end
  end
end
