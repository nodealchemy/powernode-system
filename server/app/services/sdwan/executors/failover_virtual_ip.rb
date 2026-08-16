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
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "system.sdwan_vip_failover"

      protected

      def perform
        vip = ::Sdwan::VirtualIp.find(params[:vip_id])

        # IMP-d952c791e264 — asked BEFORE prefer_target!, which persists a
        # reordered failover_holder_peer_ids with its own update! and is NOT
        # inside failover!'s transaction. Checking only inside failover! (as
        # the raise at the end of this chain does) means a failover refused on
        # state that moved during the approval window still leaves the queue
        # permanently rewritten by the operation that was refused. Named
        # target included, since that is the peer prefer_target! is about to
        # promote.
        blocker = vip.failover_blocker(target_peer_id: params[:target_peer_id])
        raise ::Sdwan::VirtualIp::StateError, blocker if blocker

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

      # IMP-8e4674f4d62d: anchored to the operation's account, on the same
      # terms as its DeleteVirtualIp twin — including why the no-name arm
      # deliberately carries no id. See that file for the reasoning.
      def summarize
        vip = scoped_label_record(::Sdwan::VirtualIp, params[:vip_id])
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
