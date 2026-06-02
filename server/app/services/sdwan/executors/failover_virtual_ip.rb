# frozen_string_literal: true

module Sdwan
  module Executors
    # Manual VIP failover — promotes the configured standby (failover-holder)
    # peer to the active holder. Always require_approval (single-holder VIPs
    # change the reachability path).
    #
    # Delegates to Sdwan::VirtualIp#failover!, the canonical mutating op that
    # rotates the holder queue AND records the assignment transition + audit
    # fields. When the operator names a target peer, it is moved to the head of
    # the failover queue first so failover! promotes it.
    class FailoverVirtualIp < ::System::Executors::Base
      protected

      def perform
        vip = ::Sdwan::VirtualIp.find(params[:vip_id])
        prefer_target!(vip, params[:target_peer_id])

        vip.failover!(
          reason: params[:reason].presence || "manual_failover",
          triggered_by_user: deferred_operation&.requested_by,
          correlation_id: deferred_operation&.id
        )

        vip.reload
        {
          vip_id: vip.id,
          holders: vip.holder_peer_ids,
          failover_holders: vip.failover_holder_peer_ids,
          state: vip.state
        }
      end

      def summarize
        vip = ::Sdwan::VirtualIp.find_by(id: params[:vip_id])
        vip ? "Failover VIP #{vip.try(:address) || vip.id}" : "Failover VIP"
      end

      def impact = "Promotes the standby holder peer — clients may see a brief drop"

      private

      # When the operator names a specific target peer, move it to the head of
      # the failover queue so failover! promotes it. No-op when the target is
      # blank or not a configured failover candidate (failover! then promotes
      # the default head).
      def prefer_target!(vip, target_peer_id)
        return if target_peer_id.blank?

        candidates = Array(vip.failover_holder_peer_ids)
        return unless candidates.include?(target_peer_id)

        vip.update!(failover_holder_peer_ids: [ target_peer_id ] + (candidates - [ target_peer_id ]))
      end
    end
  end
end
