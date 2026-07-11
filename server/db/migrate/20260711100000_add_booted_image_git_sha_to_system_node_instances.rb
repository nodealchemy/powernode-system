# frozen_string_literal: true

# Smooth Boot-Image Upgrades (campaign 019f505f) increment 1 — boot-image
# identity + drift visibility. The disk image now bakes its build git_sha into
# the UKI kernel cmdline (powernode.image_git_sha=) and /etc/powernode/boot-image.json;
# the agent reports the sha it actually booted from in its heartbeat. This column
# stores that reported value so BootImageDriftSensor can compare it against the
# platform's currently-promoted disk_image_git_sha. Nullable — nodes on older
# agents (or images built before this increment) simply don't report it.
class AddBootedImageGitShaToSystemNodeInstances < ActiveRecord::Migration[8.1]
  def change
    add_column :system_node_instances, :booted_image_git_sha, :string
  end
end
