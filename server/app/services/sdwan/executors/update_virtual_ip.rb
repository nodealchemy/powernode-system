# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdateVirtualIp < ::System::Executors::Base
      protected

      # IMP-0e44cf2fc80b — the holder-sync side-effect fires HERE, not on the
      # surfaces: gate! / gated_result never invoke their proceed blocks on
      # the :pending branch, so a sync left on VirtualIpsController#update
      # would silently not happen on every APPROVED holder change — the row
      # updated, the slice-9b assignment audit trail didn't ("no phantom
      # current state without a history row"). The canonical diff-based sync
      # lives on Sdwan::VirtualIp#sync_holder_assignments!; attribution is
      # this operation's requesting user, riding the DeferredOperation across
      # the approval window (Base#requesting_user — nil-safe across the
      # duck-typed composition contexts).
      def perform
        vip = resolve_scoped(::Sdwan::VirtualIp, params[:vip_id])
        # holder_peers_belong_to_network is RELATIVE to the VIP's network, so
        # a foreign sdwan_network_id (plus that network's peers as holders)
        # passes every validation and Sdwan::TopologyCompiler#vips_held_by
        # walks the row into the victim network's agent payloads. Guard
        # semantics live on Base#anchor_reparent! (IMP-0e44cf2fc80b); once
        # the network is anchored, the relative validation transitively
        # anchors the holders.
        anchor_reparent!(:sdwan_network_id, ::Sdwan::Network)
        ::Sdwan::VirtualIp.transaction do
          previous_holders = Array(vip.holder_peer_ids).dup
          vip.update!(attrs)
          vip.sync_holder_assignments!(previous_holders, triggered_by_user: requesting_user)
        end
        { vip_id: vip.id }
      end

      # IMP-3a563becb7d7 convention: #summarize is the approval/notification
      # body (Ai::DeferredOperationApprovalContent renders preview[:summary]),
      # and the sentence matches VirtualIpsController#update's gate
      # description verbatim so the two surfaces naming this one operation
      # cannot disagree (the IMP-ee57d0fbe859 lesson, UpdatePortMapping
      # precedent). The bare id is only the floor for a row already gone.
      def summarize
        vip = ::Sdwan::VirtualIp.find_by(id: params[:vip_id])
        return "Update VIP #{params[:vip_id]}" unless vip

        "Update SDWAN VIP '#{vip.name}' on network #{vip.network.name}"
      end
    end
  end
end
