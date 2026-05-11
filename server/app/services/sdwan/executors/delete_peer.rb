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
        endpoint = peer.respond_to?(:endpoint) ? peer.endpoint : nil
        peer.destroy!
        { peer_id: params[:peer_id], endpoint: endpoint, destroyed: true }
      end

      def summarize
        peer = ::Sdwan::Peer.find_by(id: params[:peer_id])
        return "Delete SDWAN peer #{params[:peer_id]}" unless peer
        "Delete SDWAN peer #{peer.try(:endpoint) || peer.id}"
      end

      def impact
        "Removes peer from network — node loses SDWAN connectivity until re-attached"
      end
    end
  end
end
