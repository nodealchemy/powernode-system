# frozen_string_literal: true

module Sdwan
  module Executors
    class CreateUserDevice < ::System::Executors::Base
      protected

      def perform
        grant = ::Sdwan::AccessGrant.find(params[:grant_id])
        device = grant.user_devices.create!(params[:attributes].to_h.symbolize_keys)
        { device_id: device.id, grant_id: grant.id }
      end

      def summarize = "Issue SDWAN VPN device config"
    end
  end
end
