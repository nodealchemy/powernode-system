# frozen_string_literal: true

require "openssl"
require "active_support/security_utils"

module System
  # Per-account, per-pipeline webhook secret for the disk-image
  # publication flow. Operators provision one of these in the UI for
  # each CI repo / pipeline that's allowed to register disk-image
  # builds against this account's NodePlatforms.
  #
  # Design notes:
  #   - `secret` is encrypted at rest via Rails ActiveRecord encryption
  #     (`encrypts :secret`). Operator sees the plaintext exactly once
  #     at create + rotate time. To recover, rotate.
  #   - `secret_preview` (first 8 chars) lets the operator UI show
  #     "this is the secret you saved earlier" without exposing the
  #     full value.
  #   - Webhook URL embeds the row's UUID — a bad/unknown webhook_id
  #     returns a 200 "unknown_webhook" response per webhook discipline
  #     (never 500 on inbound webhook hits).
  #   - status enum (active|disabled|revoked) lets operators temporarily
  #     pause a pipeline without losing audit data (rotation count,
  #     last_received_at, etc.).
  #
  # HMAC verification: SHA-256, header format `X-Powernode-Signature: sha256=<hex>`.
  # Mirrors the convention used by GitHub + Gitea webhooks so CI authors
  # already know it.
  #
  # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 1).
  class DiskImageWebhook < BaseRecord
    self.table_name = "system_disk_image_webhooks"

    STATUSES = %w[active disabled revoked].freeze

    encrypts :secret

    belongs_to :account
    belongs_to :created_by, class_name: "User", optional: true
    has_many :disk_image_publications, class_name: "System::DiskImagePublication",
                                       foreign_key: :webhook_id, dependent: :nullify

    validates :label, presence: true, length: { maximum: 100 },
                      uniqueness: { scope: :account_id, case_sensitive: false }
    validates :secret, presence: true
    validates :secret_preview, presence: true, length: { is: 8 }
    validates :status, inclusion: { in: STATUSES }

    scope :active, -> { where(status: "active") }

    # Operator-facing factory. Returns the persisted webhook AND the
    # plaintext secret in a tuple — caller MUST capture the secret
    # because it cannot be recovered later (only the encrypted
    # ciphertext is persisted; rotating produces a new value).
    def self.create_with_secret!(attrs)
      secret = "pndis_#{SecureRandom.urlsafe_base64(32)}"
      record = new(attrs.merge(secret: secret, secret_preview: secret[0, 8]))
      record.save!
      [record, secret]
    end

    # Rotates the secret. Returns the new plaintext exactly once.
    # Stamps last_rotated_at for the operator UI to surface.
    def rotate_secret!
      new_secret = "pndis_#{SecureRandom.urlsafe_base64(32)}"
      update!(
        secret: new_secret,
        secret_preview: new_secret[0, 8],
        last_rotated_at: Time.current
      )
      new_secret
    end

    # Constant-time HMAC-SHA256 verification.
    # Header format: "sha256=<hex>" (matches Gitea + GitHub webhook conventions).
    # Returns false (never raises) on any malformed input — webhook
    # discipline says respond 200 with an error body, never crash.
    def verify_signature(raw_body, signature_header)
      return false if signature_header.blank? || raw_body.blank?

      provided = signature_header.start_with?("sha256=") ? signature_header.split("=", 2).last : signature_header
      return false if provided.blank?

      expected = ::OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body)
      ::ActiveSupport::SecurityUtils.secure_compare(provided, expected)
    rescue StandardError => e
      ::Rails.logger.warn("[DiskImageWebhook] verify_signature error: #{e.class}: #{e.message}")
      false
    end

    # Bumps received_count + stamps last_received_at. Used by the
    # webhook controller on every inbound hit (post-signature-verify),
    # so the operator UI can show "last seen 2m ago" + "received 47
    # times since rotation".
    def record_received!
      update_columns(
        last_received_at: Time.current,
        received_count: received_count + 1,
        updated_at: Time.current
      )
    end
  end
end
