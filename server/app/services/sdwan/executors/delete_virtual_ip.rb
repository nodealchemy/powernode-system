# frozen_string_literal: true

module Sdwan
  module Executors
    class DeleteVirtualIp < ::System::Executors::Base
      protected

      def perform
        vip = ::Sdwan::VirtualIp.find(params[:vip_id])
        addr = vip.try(:address)
        vip.destroy!
        { vip_id: params[:vip_id], address: addr, destroyed: true }
      end

      # IMP-8e4674f4d62d: anchored to the operation's account (was a bare
      # `find_by(id:)`). What leaks here is thinner than its siblings and it is
      # still a leak: `vip.try(:address)` is a DEAD rung — Sdwan::VirtualIp has
      # no `address` method or column, the address lives in `cidr` — so the
      # named arm renders the id the caller already supplied. The card
      # therefore discloses only EXISTENCE, and that is exactly why the id must
      # NOT be added to the no-name arm: identical text on both arms would
      # erase the one observable and make the anchor unverifiable.
      #
      # Repairing the rung (offer 01a00899-026d) turns this into an ordinary
      # name disclosure; the anchor is already in place for that day.
      def summarize
        vip = scoped_label_record(::Sdwan::VirtualIp, params[:vip_id])
        vip ? "Delete SDWAN VIP #{vip.try(:address) || vip.id}" : "Delete SDWAN VIP"
      end

      def impact = "Releases the floating IP — services bound to it lose reachability"
    end
  end
end
