# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.peer_create` — adds a peer to a SDWAN network.
    # Most peer creates are auto-approved (additive operation), but the
    # AutonomyGate audit row + chain-of-custody is still useful.
    class CreatePeer < ::System::Executors::Base
      protected

      def perform
        network = ::Sdwan::Network.find(params[:network_id])
        peer = network.peers.create!(attrs)
        # IMP-ee57d0fbe859: record the connectivity tuple in the same shape
        # Sdwan::Executors::DeletePeer records on removal. This read
        # `peer.try(:endpoint)` — Sdwan::Peer has no `endpoint` method or column,
        # so every create row reported endpoint: nil and no auditor could
        # correlate "which endpoint was added" with "which endpoint was removed".
        { peer_id: peer.id, network_id: network.id, endpoint: peer.primary_endpoint }
      end

      def summarize
        "Add SDWAN peer to network #{params[:network_id]}"
      end

      def impact
        "Onboards a new node into the overlay network"
      end
    end
  end
end
