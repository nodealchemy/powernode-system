# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.peer_delete` — removes an SDWAN peer record. Triggered
    # via Ai::AutonomyGate from `Api::V1::System::Sdwan::PeersController#destroy`.
    # The peer's destroy callbacks handle peer-config cleanup + adjacent
    # bookkeeping (FRR re-render, key revocation, etc).
    class DeletePeer < ::System::Executors::Base
      protected

      def perform
        peer = ::Sdwan::Peer.find(params[:peer_id])
        # Read the connectivity tuple BEFORE the row goes away — this is the
        # only record of which endpoint was removed once the peer is gone.
        endpoint = peer.primary_endpoint
        peer.destroy!
        { peer_id: params[:peer_id], endpoint: endpoint, destroyed: true }
      end

      def summarize
        peer = ::Sdwan::Peer.find_by(id: params[:peer_id])
        return "Delete SDWAN peer #{params[:peer_id]}" unless peer
        "Delete SDWAN peer #{peer_label(peer)}"
      end

      def impact
        "Removes peer from network — node loses SDWAN connectivity until re-attached"
      end

      private

      # Name the peer the way the operator reading the approval card recognizes
      # it: the node instance it connects, then its reachable endpoint, and the
      # bare UUID only when nothing else identifies it. IMP-b49dd405502a: this
      # previously read `peer.try(:endpoint)`, and Sdwan::Peer has no `endpoint`
      # method or column — so every card degraded to the UUID rung.
      def peer_label(peer)
        instance = peer.node_instance
        operator_name = instance&.name.presence || instance&.discovered_hostname.presence
        return operator_name if operator_name

        format_endpoint(peer.primary_endpoint) || peer.id
      end

      # `{ host:, port:, family: }` → "host:port", bracketing v6 literals so the
      # port stays unambiguous. Sdwan::Peer only ever reports :v4 or :v6.
      def format_endpoint(endpoint)
        return nil if endpoint.blank?

        host = endpoint[:family] == :v6 ? "[#{endpoint[:host]}]" : endpoint[:host]
        "#{host}:#{endpoint[:port]}"
      end
    end
  end
end
