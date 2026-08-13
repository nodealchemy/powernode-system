# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdateVirtualIp < ::System::Executors::Base
      protected

      def perform
        vip = resolve_scoped(::Sdwan::VirtualIp, params[:vip_id])
        vip.update!(attrs)
        { vip_id: vip.id }
      end

      def summarize = "Update VIP #{params[:vip_id]}"
    end
  end
end
