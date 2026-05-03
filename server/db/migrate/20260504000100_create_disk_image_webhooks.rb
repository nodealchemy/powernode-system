# frozen_string_literal: true

# Per-account webhook secrets for the disk-image publication flow.
# Each row represents one CI pipeline / one Gitea repo that's
# authorized to register disk-image builds against this account's
# NodePlatforms. Operators can rotate or revoke individual webhook
# secrets without affecting other CI pipelines (compare to a single
# global secret, which would require coordinating rotation across
# every CI runner simultaneously).
#
# Webhook URL shape: /api/v1/system/webhooks/disk_image/built/:webhook_id
#   The :webhook_id segment scopes the request to a specific row,
#   which derives the account scope. Bad webhook_id → "unknown_webhook"
#   error response (200 — never 500 per webhook discipline).
#
# Secret storage: encrypted at rest via Rails ActiveRecord encryption
# (`encrypts :secret`). Operator sees plaintext exactly once at create
# + rotate time. The `secret_preview` column holds the first 8 chars
# so the operator UI can show "...which secret is this?" disambiguation
# without exposing the full value.
#
# Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 1).
class CreateDiskImageWebhooks < ActiveRecord::Migration[8.1]
  def change
    create_table :system_disk_image_webhooks, id: :uuid do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid

      t.string :label, null: false,
               comment: "Operator-chosen identifier (e.g. 'main-ci', 'release-pipeline')"
      t.text :secret, null: false,
             comment: "HMAC secret for X-Powernode-Signature verification. Encrypted at rest via `encrypts :secret`. Plaintext shown to operator exactly once at create/rotate."
      t.string :secret_preview, null: false,
               comment: "First 8 chars of the secret for operator UI disambiguation (so they can identify which secret is which without seeing the full value)."
      t.string :status, null: false, default: "active",
               comment: "active|disabled|revoked"

      t.references :created_by, null: true, type: :uuid,
                   foreign_key: { to_table: :users }

      t.datetime :last_received_at
      t.integer :received_count, default: 0, null: false
      t.datetime :last_rotated_at

      t.timestamps
    end

    # Operator UI lists active webhooks per account; label scoping
    # prevents two pipelines from accidentally claiming the same name.
    add_index :system_disk_image_webhooks, %i[account_id label], unique: true,
              name: "idx_diw_account_label_unique"
    add_index :system_disk_image_webhooks, :status
  end
end
