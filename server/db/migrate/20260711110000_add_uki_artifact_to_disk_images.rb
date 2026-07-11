# frozen_string_literal: true

# Smooth Boot-Image Upgrades (campaign 019f505f) increment 2 — the in-place
# upgrade path pulls just the UKI (the bootable BOOTX64.EFI), not the full ~1GB
# disk image. CI now publishes the raw UKI as its own cosign-signed OCI artifact
# so the agent can pull the exact bytes it writes to the ESP and verify the
# signature over precisely what boots.
#
# uki_oci_ref  — OCI reference of the standalone UKI artifact (null until a
#                publication built with the increment-2 CI ships one).
# uki_sha256   — sha256 of the UKI blob, for the agent's content-address check.
#
# Recorded on the publication at ingest, copied onto the platform at promote
# (mirrors the existing disk_image_oci_ref / disk_image_sha256 pair).
class AddUkiArtifactToDiskImages < ActiveRecord::Migration[8.1]
  def change
    add_column :system_disk_image_publications, :uki_oci_ref, :string
    add_column :system_disk_image_publications, :uki_sha256, :string

    add_column :system_node_platforms, :disk_image_uki_oci_ref, :string
    add_column :system_node_platforms, :disk_image_uki_sha256, :string
  end
end
