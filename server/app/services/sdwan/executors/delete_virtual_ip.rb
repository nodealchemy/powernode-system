# frozen_string_literal: true

module Sdwan
  module Executors
    class DeleteVirtualIp < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "sdwan.virtual_ip_delete"

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
