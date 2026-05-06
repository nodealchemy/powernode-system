# frozen_string_literal: true

# Adds disk-image publication metadata + cosign trust policy to
# NodePlatform. Companion to the new DiskImagePublication history
# table — these columns hold the *current active* publication's facts
# so the operator-facing download endpoint and UI banner can render
# from a single row, without joining the publication history every
# request.
#
# Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 1).
class AddDiskImagePublicationColumnsToNodePlatforms < ActiveRecord::Migration[8.1]
  def change
    change_table :system_node_platforms, bulk: true do |t|
      t.string :cosign_identity_regexp,
               comment: "Sigstore Fulcio identity regexp the publication processor will accept (e.g. 'https://registry.example.com/powernode/.+')"
      t.string :cosign_issuer_regexp,
               comment: "Sigstore Fulcio OIDC issuer regexp (e.g. 'https://registry.example.com')"
      t.string :disk_image_oci_ref,
               comment: "Last-published OCI reference (e.g. registry.example.com/powernode/disk-images/ubuntu-24.04-rpi4:abc123)"
      t.string :disk_image_git_sha,
               comment: "Git SHA of the source build that produced the active disk image"
      t.string :disk_image_publication_status,
               default: "none", null: false,
               comment: "none|verifying|published|failed — operator-facing status"
      t.text :disk_image_publication_error,
             comment: "Last error message if disk_image_publication_status='failed'"
      t.integer :disk_image_retention_count,
                default: 3, null: false,
                comment: "Number of historical publications to retain before reaper purges (per platform)"
    end
  end
end
