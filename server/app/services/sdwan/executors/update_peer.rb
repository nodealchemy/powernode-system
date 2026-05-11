# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.peer_update` — changes peer endpoint/LAN subnets.
    # `notify_and_proceed` by default — most updates are reversible.
    class UpdatePeer < ::System::Executors::Base
      protected

      def perform
        peer = ::Sdwan::Peer.find(params[:peer_id])
        peer.update!(params[:attributes].to_h.symbolize_keys)
        { peer_id: peer.id, updated_attributes: params[:attributes] }
      end

      def summarize
        "Update SDWAN peer #{params[:peer_id]}"
      end
    end
  end
end
