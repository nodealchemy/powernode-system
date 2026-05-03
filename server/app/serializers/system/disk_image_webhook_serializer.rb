# frozen_string_literal: true

module System
  # Serializer for DiskImageWebhook. CRITICAL: never returns the
  # secret plaintext — only secret_preview (first 8 chars) so operators
  # can disambiguate which secret is which without exposure.
  #
  # Plaintext is returned EXCLUSIVELY by the controller's create +
  # rotate_secret responses (and only once, never persisted).
  #
  # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 3).
  class DiskImageWebhookSerializer
    def initialize(webhook)
      @webhook = webhook
    end

    def as_json
      {
        id:                @webhook.id,
        account_id:        @webhook.account_id,
        label:             @webhook.label,
        status:            @webhook.status,
        # secret_preview is the first 8 chars of the plaintext —
        # enough to disambiguate "is this the secret I saved last week?"
        # without enabling reuse. The full secret is never returned.
        secret_preview:    @webhook.secret_preview,
        last_received_at:  @webhook.last_received_at,
        received_count:    @webhook.received_count,
        last_rotated_at:   @webhook.last_rotated_at,
        created_by_id:     @webhook.created_by_id,
        webhook_url_path:  "/api/v1/system/webhooks/disk_image/built/#{@webhook.id}",
        created_at:        @webhook.created_at,
        updated_at:        @webhook.updated_at
      }
    end
  end
end
