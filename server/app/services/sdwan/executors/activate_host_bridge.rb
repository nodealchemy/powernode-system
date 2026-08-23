# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.host_bridge_update` (IMP-97c7b4123d8f).
    #
    # Activation is the step that makes a bridge VISIBLE to the compiler —
    # `compilable` emits active|draining only — so it is the moment the row
    # starts affecting the node, not a bookkeeping flag.
    class ActivateHostBridge < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.host_bridge_update"

      protected

      def perform
        bridge = resolve_scoped(::Sdwan::HostBridge, params[:host_bridge_id])
        unless bridge.mark_active!
          hint = bridge.state == "removed" ? " — use readopt to revive a removed bridge" : ""
          raise ArgumentError, "cannot activate a #{bridge.state} host bridge#{hint}"
        end

        { host_bridge_id: bridge.id, state: bridge.reload.state }
      end

      def summarize = "Activate SDWAN host bridge #{(scoped_label_record(::Sdwan::HostBridge, params[:host_bridge_id])&.bridge_name || params[:host_bridge_id])}"
      def impact    = "Makes the bridge visible to the compiler, which emits it onto the node"
    end
  end
end
