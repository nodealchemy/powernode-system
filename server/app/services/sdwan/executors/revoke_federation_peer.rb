# frozen_string_literal: true

module Sdwan
  module Executors
    class RevokeFederationPeer < ::System::Executors::Base
      protected

      # `reason` is optional but never discardable: this is a cross-instance
      # trust withdrawal, and the audited cause is the point of recording it.
      # It rides through to FederationPeer#revoke!, which stores it as
      # metadata["revocation_reason"] — the value every read-back projects.
      #
      # Two controller actions reach this executor under the same
      # `sdwan.federation_peer_revoke` gate, and only one supplies a reason:
      # #revoke (POST) forwards params[:reason]; #destroy (DELETE) sends only
      # the peer id, so a DELETE-shaped revocation is reason-less by
      # construction, not by this bug. The MCP action
      # system_sdwan_revoke_federation_peer does NOT come through here at all —
      # it calls FederationPeer#revoke! directly (and, unlike these two, is
      # ungated).
      #
      # The former `respond_to?(:revoke!)` fallback wrote a `revoked_at` column
      # that system_federation_peers does not have, so it could only ever raise;
      # it was also the arm that dropped the reason. revoke! is defined on the
      # model unconditionally, so there is nothing to fall back from.
      def perform
        peer = ::System::FederationPeer.find(params[:federation_peer_id])
        peer.revoke!(reason: params[:reason])
        { federation_peer_id: peer.id, revoked: true }
      end

      def summarize = "Revoke federation peer #{params[:federation_peer_id]}"
      def impact    = "Cuts cross-instance routing — federated traffic stops immediately"
    end
  end
end
