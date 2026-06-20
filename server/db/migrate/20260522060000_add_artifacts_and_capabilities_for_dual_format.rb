# frozen_string_literal: true

# Dual-format module artifact support — the managed-child dogfood
# uncovered that Ubuntu 24.04's stock kernel disables CONFIG_COMPOSEFS,
# while Fedora and (eventually) custom-kernel builds ship it. To let
# the platform meet each managed-instance where its kernel is, modules
# can now publish in BOTH composefs and squashfs formats and agents
# pick the right one based on their detected capabilities.
#
# Two changes:
#
#   1. `system_node_module_versions.artifacts` JSONB — holds per-format
#      artifact metadata. Shape:
#        {
#          "composefs": {
#            "oci_ref":        "git.powernode.org/.../mod:tag",
#            "digest":         "sha256:...",
#            "fsverity_root":  "sha256:...",
#            "size":           1662976,
#            "media_type":     "application/vnd.powernode.composefs"
#          },
#          "squashfs": { ... same shape, format-specific values }
#        }
#      The pre-existing top-level columns (oci_digest, fsverity_root_hash,
#      data_file_size) remain as the "primary" format hint for backward
#      compat with code paths that haven't migrated; new code should read
#      via `artifacts.dig(format, ...)`.
#
#   2. `system_node_instances.capabilities` JSONB — agent-reported
#      detected capabilities. Shape:
#        {
#          "kernel_version":      "6.8.0-106-generic",
#          "composefs_available": false,
#          "squashfs_available":  true,
#          "fsverity_available":  true,
#          "overlayfs_available": true,
#          "detected_at":         "2026-05-22T07:00:00Z"
#        }
#      Refreshed on every heartbeat. Used by ModulesController#show to
#      decide which artifact format to surface in the manifest response.
#
# GIN indexes on both so capability queries ("which nodes support
# composefs?") and artifact queries ("which versions have a squashfs
# artifact?") stay sub-second at fleet scale.
class AddArtifactsAndCapabilitiesForDualFormat < ActiveRecord::Migration[8.0]
  def change
    add_column :system_node_module_versions, :artifacts, :jsonb, default: {}, null: false
    add_index :system_node_module_versions, :artifacts, using: :gin

    add_column :system_node_instances, :capabilities, :jsonb, default: {}, null: false
    add_index :system_node_instances, :capabilities, using: :gin
  end
end
