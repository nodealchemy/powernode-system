# frozen_string_literal: true

module System
  module Executors
    module DiskImage
      # Multi-action executor for disk image webhooks. Backs three deferred
      # operations the operator surface raises through AutonomyGate:
      #
      #   action: "trigger"        — manual re-fire marker (no-op today; the
      #                              concrete dispatch lives in the receiver).
      #   action: "revoke"         — soft-revoke the webhook (status flip).
      #   action: "rotate_secret"  — mint a fresh HMAC secret + invalidate
      #                              the prior; returns plaintext exactly once.
      #
      # The controller's `on_proceed:` closure performs the same work
      # synchronously when policy is auto_approve / notify_and_proceed. This
      # executor runs the deferred (require_approval) path after operator
      # approval clicks through the deferred-operation queue.
      class TriggerWebhook < ::System::Executors::Base
        protected

        def perform
          webhook = ::System::DiskImageWebhook.find(params[:webhook_id])
          case params[:action].to_s
          when "revoke"
            webhook.update!(status: "revoked") if webhook.status != "revoked"
            { webhook_id: webhook.id, action: "revoke", status: webhook.status }
          when "rotate_secret"
            new_secret = webhook.rotate_secret!
            emit_rotated_event(webhook)
            { webhook_id: webhook.id, action: "rotate_secret", secret_plaintext: new_secret }
          else
            # "trigger" (or missing) — manual re-fire marker; the actual
            # dispatch is the receiver's responsibility.
            { webhook_id: webhook.id, action: "trigger", triggered_at: Time.current.iso8601 }
          end
        end

        def summarize
          action = params[:action].to_s.presence || "trigger"
          "#{action.capitalize} disk image webhook #{params[:webhook_id]}"
        end

        private

        def emit_rotated_event(webhook)
          return unless defined?(::System::Fleet::EventBroadcaster)

          ::System::Fleet::EventBroadcaster.emit!(
            account:  webhook.account,
            kind:     "system.disk_image_webhook_secret_rotated",
            severity: :medium,
            source:   "autonomy_executor",
            payload:  { webhook_id: webhook.id, label: webhook.label }
          )
        rescue StandardError => e
          Rails.logger.warn "[DiskImage::TriggerWebhook] rotated event emit failed: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
