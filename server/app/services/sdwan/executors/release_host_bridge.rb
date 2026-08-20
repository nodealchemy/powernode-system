# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.host_bridge_delete` (IMP-97c7b4123d8f).
    #
    # `force: true` skips the draining grace window that lets in-flight taps
    # settle before the short_id is reusable, so this carries the delete tier
    # its siblings do.
    class ReleaseHostBridge < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.host_bridge_delete"

      protected

      def perform
        bridge = resolve_scoped(::Sdwan::HostBridge, params[:host_bridge_id])
        ::Sdwan::HostBridgeAllocator.release!(bridge, force: params[:force] == true)
        { host_bridge_id: bridge.id, state: bridge.reload.state, forced: params[:force] == true }
      end

      def summarize
        forced = params[:force] == true ? " (forced)" : ""
        "Release SDWAN host bridge #{(scoped_label_record(::Sdwan::HostBridge, params[:host_bridge_id])&.bridge_name || params[:host_bridge_id])}#{forced}"
      end

      def impact = "Removes the bridge from the node; forced release skips the draining window"
    end
  end
end
