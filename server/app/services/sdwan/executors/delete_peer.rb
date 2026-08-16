# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.peer_delete` — removes an SDWAN peer record. Triggered
    # via Ai::AutonomyGate from `Api::V1::System::Sdwan::PeersController#destroy`.
    # The peer's destroy callbacks handle peer-config cleanup + adjacent
    # bookkeeping (FRR re-render, key revocation, etc).
    class DeletePeer < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "sdwan.peer_delete"

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
      #
      # IMP-8e4674f4d62d: through the operation's account anchor, the way its
      # UpdatePeer twin already resolves the identical param. operator_label
      # names a node instance AND a network, so an unanchored find_by handed a
      # foreign peer id put two of another account's resource names on this
      # account's approval card. It also restores IMP-ee57d0fbe859's invariant
      # structurally rather than by coincidence: while one twin was anchored
      # and the other was not, the two cards named the same peer identically
      # only for as long as both previews happened to receive the same anchor.
      def summarize
        peer = scoped_label_record(::Sdwan::Peer, params[:peer_id])
        return "Delete SDWAN peer #{params[:peer_id]}" unless peer
        "Delete SDWAN peer #{peer.operator_label}"
      end

      def impact
        "Removes peer from network — node loses SDWAN connectivity until re-attached"
      end
    end
  end
end
