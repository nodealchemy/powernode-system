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

      def summarize
        vip = ::Sdwan::VirtualIp.find_by(id: params[:vip_id])
        vip ? "Delete SDWAN VIP #{vip.try(:address) || vip.id}" : "Delete SDWAN VIP"
      end

      def impact = "Releases the floating IP — services bound to it lose reachability"
    end
  end
end
