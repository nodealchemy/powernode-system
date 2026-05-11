# frozen_string_literal: true

module Sdwan
  module Executors
    class RevokeFederationPeer < ::System::Executors::Base
      protected

      def perform
        peer = ::Sdwan::FederationPeer.find(params[:federation_peer_id])
        if peer.respond_to?(:revoke!)
          peer.revoke!
        else
          peer.update!(status: "revoked", revoked_at: Time.current)
        end
        { federation_peer_id: peer.id, revoked: true }
      end

      def summarize = "Revoke federation peer #{params[:federation_peer_id]}"
      def impact    = "Cuts cross-instance routing — federated traffic stops immediately"
    end
  end
end
