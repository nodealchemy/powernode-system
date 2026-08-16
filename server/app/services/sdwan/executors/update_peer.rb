# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.peer_update` — changes peer endpoint/LAN subnets.
    # `notify_and_proceed` by default — most updates are reversible.
    class UpdatePeer < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "sdwan.peer_update"

      protected

      def perform
        peer = resolve_scoped(::Sdwan::Peer, params[:peer_id])
        # IMP-c159cc6777b1: Sdwan::TopologyCompiler reads peers back through
        # `network.peers.includes(:keys)` with no account filter, so a foreign
        # sdwan_network_id would land this peer in the victim's overlay.
        # Guard semantics live on Base#anchor_reparent! (IMP-0e44cf2fc80b).
        anchor_reparent!(:sdwan_network_id, ::Sdwan::Network)
        peer.update!(attrs)
        { peer_id: peer.id, updated_attributes: params[:attributes] }
      end

      # IMP-3a563becb7d7: the label is Sdwan::Peer#operator_label — the same
      # ladder both peer-delete surfaces render (IMP-ee57d0fbe859). This card
      # read a bare peer UUID, so the update and delete rows for one peer did
      # not visibly concern the same subject.
      #
      # IMP-4a5094b22df0: through the same account anchor `perform` resolves by.
      # It was a bare `find_by(id:)` — the identical param, resolved scoped for
      # the write and unscoped for the sentence, so a caller that did not
      # pre-scope had another account's peer named on its approvers' card.
      def summarize
        peer = scoped_label_record(::Sdwan::Peer, params[:peer_id])
        return "Update SDWAN peer #{params[:peer_id]}" unless peer

        "Update SDWAN peer #{peer.operator_label}"
      end

      # No #impact override here, deliberately (IMP-35bc8eda71ad). This executor
      # is the whole reason the field naming lives on Base rather than on each
      # subclass: `system_sdwan_update_peer_lan_subnets` and
      # `system_sdwan_set_peer_tags` are gated as ONE action through this one
      # class, so #summarize and the two gate `description:` strings are — and
      # must remain — identical for both. Before the field list, that made a
      # change rewriting AllowedIPs for every peer routing to this one render a
      # card byte-identical to a cosmetic tag relabel.
      #
      # Prose here could only say what is true of BOTH arms, which is what the
      # card already said. `Sets fields: lan_subnets` versus `Sets fields: tags`
      # is the distinction the approver needs, and Base composes it from the
      # parked attributes. Anything added here is appended, never substituted.
    end
  end
end
