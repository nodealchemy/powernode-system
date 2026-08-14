# frozen_string_literal: true

module Sdwan
  module Executors
    class CreateVirtualIp < ::System::Executors::Base
      protected

      # IMP-6c482005db87 — the whole create ceremony lives HERE, not on the
      # surfaces: gate! / gated_result never invoke their proceed blocks on
      # the :pending branch, so anything a surface performed after save would
      # silently not happen on an approved create. That ceremony is slice
      # 9b's own invariant: a holder-bearing VIP activates, and its current
      # state is backed by an assignment history row from row 0 — "no
      # phantom current state without a history row". Internal composition
      # (ServiceDiscoveryComposerExecutor) reaches this same primitive
      # synchronously and ungated, and gets the identical ceremony.
      def perform
        network = resolve_scoped(::Sdwan::Network, params[:network_id])
        vip = ::Sdwan::VirtualIp.transaction do
          network.virtual_ips.new(attrs).tap do |v|
            v.activate_if_held
            v.save!
            create_initial_assignments!(v)
          end
        end
        { vip_id: vip.id, address: vip.try(:address) }
      end

      # IMP-3a563becb7d7: this is the approval/notification body
      # (Ai::DeferredOperationApprovalContent.title and .message both render
      # preview[:summary]). It read "Allocate SDWAN VIP on network <uuid>" —
      # a bare network UUID, naming neither the VIP nor a network the operator
      # recognises. The VIP does not exist yet, so the card is composed from
      # what the request already names, mirroring CreatePeer
      # (IMP-1eba7d50d24c).
      def summarize
        vip_name = attrs[:name].presence
        label = network_label.presence
        [
          "Allocate SDWAN VIP",
          ("'#{vip_name}'" if vip_name),
          ("on network #{label}" if label)
        ].compact.join(" ")
      end

      private

      # Slice 9b — initial assignment row for the primary holder (or every
      # holder if anycast), moved verbatim from the two inline surfaces.
      # Attribution: the requesting user rides the DeferredOperation across
      # the approval window (Base#requesting_user — nil-safe across the
      # duck-typed composition contexts and the composer's literal nil).
      def create_initial_assignments!(vip)
        holders = vip.anycast? ? Array(vip.holder_peer_ids) : Array(vip.holder_peer_ids).first(1)
        holders.compact.each do |peer_id|
          vip.assignments.create!(
            peer: ::Sdwan::Peer.find(peer_id),
            assumed_at: Time.current,
            reason: "initial",
            triggered_by_user_id: requesting_user&.id
          )
        end
      end

      # Scoped to the account the create attributes carry: deferred_operation
      # is nil on the preview path (Base.preview hardcodes it), and absent an
      # account id the lookup is skipped rather than run unscoped — an
      # approval card must not name another account's rows (IMP-1eba7d50d24c).
      def target_network
        return @target_network if defined?(@target_network)

        @target_network =
          if requested_account_id.present? && params[:network_id].present?
            ::Sdwan::Network.find_by(id: params[:network_id], account_id: requested_account_id)
          end
      end

      def network_label
        target_network&.name.presence || params[:network_id]
      end
    end
  end
end
