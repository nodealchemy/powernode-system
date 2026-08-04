# frozen_string_literal: true

# IMP-dbd848ce393c — drop the write-only UKI mirror columns from
# system_node_platforms.
#
# 20260711110000_add_uki_artifact_to_disk_images added the UKI pins in two
# places at once: on the publication row (uki_oci_ref / uki_sha256) and mirrored
# onto the parent platform (disk_image_uki_oci_ref / disk_image_uki_sha256),
# following the existing disk_image_oci_ref / disk_image_sha256 shape.
#
# Two later fixes moved every reader onto the publication row —
# IMP-4452cb88e195 unified plan + dispatch on it, IMP-b55869029a57 made the
# download endpoint resolve a publication — leaving the platform pair a pure
# write-only mirror: three writers, zero readers. That is not merely dead
# weight. The mirror can drift out of step with disk_image_git_sha (a
# partial-field promote updates one and not the other), and a stale pin is what
# made a node download one image's UKI and cosign-verify it against a different
# image's bundle. Both fixes above were cleaning up after exactly that drift.
#
# The publication row keeps the pins and remains the single source of truth;
# system_disk_image_publications is untouched here. The platform's non-UKI
# pointers (disk_image_git_sha / disk_image_oci_ref / ...) also stay — they
# answer "what do newly provisioned nodes boot", which is a real question the
# platform is responsible for.
#
# Reversible: down() restores the original column shape from 20260711110000
# (plain :string, nullable, no default). It deliberately does NOT restore
# values — they were only ever copies of the promoted publication, so a promote
# or rollback repopulates them if the columns ever come back.
class DropUkiMirrorColumnsFromNodePlatforms < ActiveRecord::Migration[8.1]
  def up
    remove_column :system_node_platforms, :disk_image_uki_oci_ref
    remove_column :system_node_platforms, :disk_image_uki_sha256
  end

  def down
    add_column :system_node_platforms, :disk_image_uki_oci_ref, :string
    add_column :system_node_platforms, :disk_image_uki_sha256, :string
  end
end
