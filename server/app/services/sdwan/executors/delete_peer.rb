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

      # IMP-ee57d0fbe859: the label is Sdwan::Peer#operator_label, shared with
      # PeersController#destroy's gate `description:`. This executor used to
      # carry its own copy of the rung ladder, which is how the two surfaces
      # naming the SAME delete came to disagree.
      def summarize
        peer = ::Sdwan::Peer.find_by(id: params[:peer_id])
        return "Delete SDWAN peer #{params[:peer_id]}" unless peer
        "Delete SDWAN peer #{peer.operator_label}"
      end

      def impact
        "Removes peer from network — node loses SDWAN connectivity until re-attached"
      end
    end
  end
end
