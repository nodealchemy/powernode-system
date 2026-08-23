# frozen_string_literal: true

module Sdwan
  module Executors
    class RevokeFederationPeer < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "sdwan.federation_peer_revoke"

      protected

      # `reason` is optional but never discardable: this is a cross-instance
      # trust withdrawal, and the audited cause is the point of recording it.
      # It rides through to FederationPeer#revoke!, which stores it as
      # metadata["revocation_reason"] — the value every read-back projects.
      #
      # Four call sites reach this executor under the same
      # `sdwan.federation_peer_revoke` gate, and one of them supplies no
      # reason: #revoke (POST) forwards params[:reason], as do the two MCP
      # arms (system_sdwan_revoke_federation_peer and
      # system_sdwan_update_federation_peer's status → "revoked" leg, both
      # routed here by IMP-2795453255c3); #destroy (DELETE) sends only the
      # peer id, so a DELETE-shaped revocation is reason-less by construction,
      # not by a bug.
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
