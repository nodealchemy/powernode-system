# frozen_string_literal: true

module Sdwan
  module Executors
    class ProposeFederationPeer < ::System::Executors::Base
      protected

      def perform
        peer = ::System::FederationPeer.create!(
          params[:attributes].to_h.symbolize_keys.merge(account: account, status: "proposed")
        )
        { federation_peer_id: peer.id }
      end

      def summarize = "Propose cross-instance federation with #{params.dig(:attributes, :remote_endpoint)}"
      def impact    = "Initiates a federation handshake with a remote Powernode instance"
    end
  end
end
