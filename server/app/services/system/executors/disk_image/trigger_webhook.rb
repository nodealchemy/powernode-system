# frozen_string_literal: true

module System
  module Executors
    module DiskImage
      class TriggerWebhook < ::System::Executors::Base
        protected

        def perform
          webhook = ::System::DiskImageWebhook.find(params[:webhook_id])
          # Manual re-fire of the webhook payload — concrete dispatch lives in
          # the webhook receiver. Stubbed as a marker.
          { webhook_id: webhook.id, triggered_at: Time.current.iso8601 }
        end

        def summarize = "Manually trigger disk image webhook #{params[:webhook_id]}"
      end
    end
  end
end
