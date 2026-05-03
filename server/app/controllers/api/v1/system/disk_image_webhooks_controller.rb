# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing CRUD for per-account disk-image webhook secrets.
      # Returns plaintext secret EXACTLY ONCE (on create + rotate).
      # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 3).
      class DiskImageWebhooksController < BaseController
        before_action :set_account
        before_action :set_webhook, only: %i[show destroy rotate_secret]

        def index
          require_permission("system.disk_image_webhooks.read")
          render_success(
            disk_image_webhooks: @account.system_disk_image_webhooks.order(created_at: :desc).map { |w|
              ::System::DiskImageWebhookSerializer.new(w).as_json
            }
          )
        end

        def show
          require_permission("system.disk_image_webhooks.read")
          render_success(disk_image_webhook: ::System::DiskImageWebhookSerializer.new(@webhook).as_json)
        end

        def create
          require_permission("system.disk_image_webhooks.create")
          webhook, secret = ::System::DiskImageWebhook.create_with_secret!(
            account: @account,
            label:   params.require(:label),
            created_by: current_user
          )
          render_success(
            disk_image_webhook: ::System::DiskImageWebhookSerializer.new(webhook).as_json,
            # SHOWN EXACTLY ONCE. Operator must save it now.
            secret_plaintext: secret,
            webhook_url: build_webhook_url(webhook),
            note: "Save this secret + URL now — the secret is not recoverable. To get a new one, rotate."
          )
        rescue ActiveRecord::RecordInvalid => e
          render_validation_error(e.record)
        end

        def destroy
          require_permission("system.disk_image_webhooks.delete")
          @webhook.update!(status: "revoked")
          render_success(message: "Webhook revoked")
        end

        # POST /api/v1/system/disk_image_webhooks/:id/rotate_secret
        def rotate_secret
          require_permission("system.disk_image_webhooks.rotate_secret")
          new_secret = @webhook.rotate_secret!
          emit_rotated_event(@webhook)
          render_success(
            disk_image_webhook: ::System::DiskImageWebhookSerializer.new(@webhook).as_json,
            secret_plaintext: new_secret,
            note: "Save this secret now — old secret is revoked. Update CI immediately."
          )
        end

        private

        def set_webhook
          @webhook = @account.system_disk_image_webhooks.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("DiskImageWebhook")
        end

        def build_webhook_url(webhook)
          base = ENV.fetch("POWERNODE_PUBLIC_URL", "http://localhost:3000")
          "#{base}/api/v1/system/webhooks/disk_image/built/#{webhook.id}"
        end

        def emit_rotated_event(webhook)
          return unless defined?(::System::Fleet::EventBroadcaster)
          ::System::Fleet::EventBroadcaster.emit!(
            account:  @account,
            kind:     "system.disk_image_webhook_secret_rotated",
            severity: :medium,
            source:   "operator_ui",
            payload:  { webhook_id: webhook.id, label: webhook.label, by_user_id: current_user&.id }
          )
        rescue StandardError => e
          Rails.logger.warn "[DiskImageWebhooks] rotated event emit failed: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
