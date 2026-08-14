# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.peer_update` — changes peer endpoint/LAN subnets.
    # `notify_and_proceed` by default — most updates are reversible.
    class UpdatePeer < ::System::Executors::Base
      protected

      def perform
        peer = resolve_scoped(::Sdwan::Peer, params[:peer_id])
        anchor_reparent!
        peer.update!(attrs)
        { peer_id: peer.id, updated_attributes: params[:attributes] }
      end

      # IMP-3a563becb7d7: the label is Sdwan::Peer#operator_label — the same
      # ladder both peer-delete surfaces render (IMP-ee57d0fbe859). This card
      # read a bare peer UUID, so the update and delete rows for one peer did
      # not visibly concern the same subject.
      def summarize
        peer = ::Sdwan::Peer.find_by(id: params[:peer_id])
        return "Update SDWAN peer #{params[:peer_id]}" unless peer

        "Update SDWAN peer #{peer.operator_label}"
      end

      private

      # IMP-c159cc6777b1: `attrs` drops account/account_id (TENANCY_ATTRIBUTE_KEYS),
      # which stops the tenancy MOVE but not the tenancy RE-PARENT. sdwan_network_id
      # is equally tenancy-bearing: Sdwan::TopologyCompiler reads the peers back
      # through `network.peers.includes(:keys)` with no account filter, so an
      # operation naming a foreign sdwan_network_id lands this peer in the victim's
      # network — account_id stays the caller's — and the victim's overlay then
      # compiles a peer it does not own. Resolving the new parent through
      # resolve_scoped is the whole guard: in-account re-parents still work, and a
      # foreign network raises CrossAccountError before update!. When no new parent
      # is named, the peer's existing network is untouched.
      def anchor_reparent!
        network_id = attrs[:sdwan_network_id]
        return if network_id.blank?

        resolve_scoped(::Sdwan::Network, network_id)
      end
    end
  end
end
