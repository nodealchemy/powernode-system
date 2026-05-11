# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdateVirtualIp < ::System::Executors::Base
      protected

      def perform
        vip = ::Sdwan::VirtualIp.find(params[:vip_id])
        vip.update!(params[:attributes].to_h.symbolize_keys)
        { vip_id: vip.id }
      end

      def summarize = "Update VIP #{params[:vip_id]}"
    end
  end
end
