# frozen_string_literal: true

module Sdwan
  module Executors
    class AcceptFederationPeer < ::System::Executors::Base
      protected

      def perform
        peer = ::System::FederationPeer.find(params[:federation_peer_id])
        if peer.respond_to?(:accept!)
          peer.accept!
        else
          peer.update!(status: "accepted", accepted_at: Time.current)
        end
        { federation_peer_id: peer.id }
      end

      def summarize = "Accept federation peer #{params[:federation_peer_id]}"
      def impact    = "Completes federation handshake; mutual route advertisement begins"
    end
  end
end
