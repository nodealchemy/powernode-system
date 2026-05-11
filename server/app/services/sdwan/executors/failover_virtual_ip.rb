# frozen_string_literal: true

module Sdwan
  module Executors
    # Manual VIP failover — flips holder_peer_ids order so a different peer
    # becomes the active holder. Always require_approval (single-holder VIPs
    # change reachability path).
    class FailoverVirtualIp < ::System::Executors::Base
      protected

      def perform
        vip = ::Sdwan::VirtualIp.find(params[:vip_id])
        # Delegate to model method if present; otherwise rotate holders manually.
        if vip.respond_to?(:failover!)
          vip.failover!(target_peer_id: params[:target_peer_id])
        elsif vip.respond_to?(:holder_peer_ids) && vip.holder_peer_ids.is_a?(Array)
          rotated = vip.holder_peer_ids.rotate
          vip.update!(holder_peer_ids: rotated)
        end
        { vip_id: vip.id, holders: vip.try(:holder_peer_ids) }
      end

      def summarize
        vip = ::Sdwan::VirtualIp.find_by(id: params[:vip_id])
        vip ? "Failover VIP #{vip.try(:address) || vip.id}" : "Failover VIP"
      end

      def impact = "Switches the active holder peer — clients may see a brief drop"
    end
  end
end
