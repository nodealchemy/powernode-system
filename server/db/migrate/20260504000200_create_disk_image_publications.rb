# frozen_string_literal: true

# Append-only history table for disk-image publications. Three jobs:
#
#   1. Idempotency anchor — unique(node_platform_id, git_sha) lets the
#      processor short-circuit re-receives without re-pulling from OCI.
#
#   2. Rollback substrate — operator can pick any prior :published row
#      and re-activate it (flips NodePlatform.disk_image_file_object_id
#      back). Without this table, "rollback" would require re-running CI.
#
#   3. Reaper boundary — the retention sweep operates on this table
#      (retire then purge), not on NodePlatform itself. Older builds
#      stay visible in operator history until purged_at is set.
#
# Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 1).
class CreateDiskImagePublications < ActiveRecord::Migration[8.1]
  def change
    create_table :system_disk_image_publications, id: :uuid do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid
      t.references :node_platform, null: false, type: :uuid,
                   foreign_key: { to_table: :system_node_platforms }
      # Active blob (nullable while status=queued/awaiting_upload/verifying).
      t.references :file_object, null: true, type: :uuid,
                   foreign_key: { to_table: :file_objects }
      # Captured at publication time so rollback can re-point platform.
      # Nullable — first ever publication has no prior.
      t.references :prior_file_object, null: true, type: :uuid,
                   foreign_key: { to_table: :file_objects }

      t.string :status, null: false, default: "queued",
               comment: "queued|awaiting_upload|verifying|published|failed|retired|purged"
      t.string :git_sha, null: false
      t.string :oci_ref,
               comment: "Source OCI artifact ref (null for direct-upload mode)"
      t.string :sha256, null: false
      t.bigint :size_bytes, null: false
      t.string :firmware_ref,
               comment: "rpi4-firmware module ref pinned at build time"
      t.string :arch, null: false

      # Cosign attestation material — kept for audit + later re-verification.
      # base64-encoded so it round-trips cleanly through JSON serializers.
      t.text :cosign_bundle,
             comment: "cosign sign-blob bundle over the .img bytes"
      t.text :attestation_bundle,
             comment: "cosign attest-blob bundle over the publication payload predicate"

      # Full inbound payload preserved for forensics — operators can
      # diff future publications against past ones without losing context.
      t.jsonb :payload, null: false, default: {}
      t.text :error_message

      t.datetime :verified_at
      t.datetime :published_at
      t.datetime :retired_at
      t.datetime :purged_at

      t.references :webhook, null: true, type: :uuid,
                   foreign_key: { to_table: :system_disk_image_webhooks }
      t.references :triggered_by_worker, null: true, type: :uuid,
                   foreign_key: { to_table: :workers }

      t.integer :attempt_count, default: 1, null: false
      t.timestamps
    end

    # Idempotency: re-received webhooks for the same git_sha hit the
    # short-circuit path in DiskImagePublicationProcessor.
    add_index :system_disk_image_publications,
              %i[node_platform_id git_sha], unique: true,
              name: "idx_dip_platform_sha_unique"

    # UI list page (DiskImageHistoryTab) filters by status per platform.
    add_index :system_disk_image_publications, %i[node_platform_id status],
              name: "idx_dip_platform_status"

    # Reaper iterates per-account batches.
    add_index :system_disk_image_publications, :status

    # Pagination ordering for operator history view.
    add_index :system_disk_image_publications,
              %i[node_platform_id created_at],
              order: { created_at: :desc },
              name: "idx_dip_platform_created_desc"
  end
end
