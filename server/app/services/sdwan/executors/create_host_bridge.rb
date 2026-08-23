# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.host_bridge_create` (IMP-97c7b4123d8f).
    #
    # Allocation is not merely a row: HostBridgeAllocator assigns a per-host
    # short_id and a bridge name the compiler emits onto the node, so an
    # ungated create reached the dataplane.
    class CreateHostBridge < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.host_bridge_create"

      protected

      def perform
        host = resolve_scoped(::System::NodeInstance, params[:node_instance_id])
        bridge = ::Sdwan::HostBridgeAllocator.allocate!(
          host: host, kind: params[:kind].presence, account: host.account
        )
        { host_bridge_id: bridge.id, node_instance_id: host.id, bridge_name: bridge.bridge_name }
      end

      def summarize = "Allocate SDWAN host bridge on #{(scoped_label_record(::System::NodeInstance, params[:node_instance_id])&.name || params[:node_instance_id])}"
      def impact    = "Creates a bridge interface the compiler emits onto the node"
    end
  end
end
