# frozen_string_literal: true

module Sdwan
  module Executors
    class CreateVirtualIp < ::System::Executors::Base
      protected

      def perform
        network = ::Sdwan::Network.find(params[:network_id])
        vip = network.virtual_ips.create!(attrs)
        { vip_id: vip.id, address: vip.try(:address) }
      end

      def summarize = "Allocate SDWAN VIP on network #{params[:network_id]}"
    end
  end
end
