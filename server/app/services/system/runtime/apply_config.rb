# frozen_string_literal: true

module System
  module Runtime
    # Applies pending configuration to a node instance. Phase 1 implementation
    # delegates to the SyncModules runtime — the typical "apply config" flow
    # is to commit all enabled modules assigned to the node, in dependency
    # order, then run sync. A future iteration may distinguish config-only
    # apply (no module rebuild) from full sync.
    class ApplyConfig
      def self.call(operation:)
        # Delegate to SyncModules — same observable behavior in Phase 1.
        ::System::Runtime::SyncModules.call(operation: operation)
      end
    end
  end
end
