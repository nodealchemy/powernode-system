# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing CRUD for per-account disk-image webhook secrets.
      # Returns plaintext secret EXACTLY ONCE (on create + rotate).
      # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 3).
      class DiskImageWebhooksController < BaseController
        include ::Ai::GatedActions

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

        # Soft-revoke the webhook (status flip). Gated through AutonomyGate
        # so revoking an active CI integration goes through the same
        # audit + optional approval flow as other infrastructure changes.
        def destroy
          require_permission("system.disk_image_webhooks.delete")
          id = @webhook.id
          label = @webhook.label
          gate!(
            action_category: "system.disk_image_webhook_revoke",
            executor_class: "System::Executors::DiskImage::TriggerWebhook",
            params: { webhook_id: id, action: "revoke" },
            source_type: "System::DiskImageWebhook",
            source_id: id,
            description: "Revoke disk image webhook '#{label}'",
            # The executor performs the status flip. This closure renders it.
            # It used to flip the status too, and the `!= "revoked"` guard did
            # not stop the second write: `@webhook` is the instance loaded
            # BEFORE the gate, so in memory it was still active. Idempotent, so
            # nothing visible broke here — which is precisely why the same
            # defect survived on the rotation path, where it is not
            # (IMP-4de09f201a0f).
            on_proceed: ->(_r) {
              render_success(message: "Webhook revoked")
            }
          )
        end

        # POST /api/v1/system/disk_image_webhooks/:id/rotate_secret
        # Rotating invalidates the old secret immediately — any in-flight CI
        # job using the old secret 401s on next push. Gated to give operators
        # an optional approval step before disrupting active builds.
        def rotate_secret
          require_permission("system.disk_image_webhooks.rotate_secret")
          id = @webhook.id
          label = @webhook.label
          gate!(
            action_category: "system.disk_image_webhook_rotate_secret",
            executor_class: "System::Executors::DiskImage::TriggerWebhook",
            params: { webhook_id: id, action: "rotate_secret" },
            source_type: "System::DiskImageWebhook",
            source_id: id,
            description: "Rotate secret for disk image webhook '#{label}'",
            # THE EXECUTOR MINTS THE SECRET. This closure only renders what it
            # returned. Both used to mint one (IMP-4de09f201a0f): two secrets
            # per rotation, the executor's immediately superseded and thrown
            # away, and two `system.disk_image_webhook_secret_rotated` fleet
            # events for one operator action.
            #
            # `secret_plaintext` is read from the executor's result rather than
            # from the row: the model returns the plaintext exactly once from
            # `rotate_secret!`, and the copy persisted on the deferred
            # operation is masked at rest by Ai::SensitiveParams. (The other
            # in-memory channel is DeferredOperation#take_revealed_result!,
            # which belongs to the approval path — Ai::ApprovalRequest is its
            # only reader.) Reload the webhook for the serializer, since
            # `@webhook` predates the executor's write.
            on_proceed: ->(result) {
              new_secret = result.result&.dig(:data, :secret_plaintext)
              @webhook.reload
              render_success(
                disk_image_webhook: ::System::DiskImageWebhookSerializer.new(@webhook).as_json,
                secret_plaintext: new_secret,
                # Same builder as #create. Both responses are consumed by one
                # frontend type with webhook_url required, and the operator's
                # one-time modal prints it for whichever action produced it —
                # so omitting it here rendered "Webhook URL: undefined" in the
                # panel telling them to update their CI configuration.
                webhook_url: build_webhook_url(@webhook),
                note: "Save this secret now — old secret is revoked. Update CI immediately."
              )
            }
          )
        end

        private

        def set_webhook
          @webhook = @account.system_disk_image_webhooks.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("DiskImageWebhook")
        end

        def build_webhook_url(webhook)
          # Path comes from the model, which is the single home for it. Kept as
          # a method rather than inlined so both render sites read the same.
          webhook.webhook_url
        end
      end
    end
  end
end
