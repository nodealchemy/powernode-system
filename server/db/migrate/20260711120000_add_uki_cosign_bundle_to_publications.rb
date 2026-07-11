# frozen_string_literal: true

# Smooth Boot-Image Upgrades (campaign 019f505f) increment 2 — deliver the UKI's
# cosign signature bundle to the on-node agent so it can verify the pulled UKI
# against the platform's pinned identity/issuer before writing it to the ESP.
#
# The bundle is small (a few KB), so CI reports it base64-encoded in the built
# webhook payload and we store it on the publication; the upgrade action passes
# it inline in the agent task options. This keeps the agent's cosign verification
# self-contained (no second registry round-trip) — the security-critical check
# happens where the bytes boot. Null on publications built before the UKI CI.
class AddUkiCosignBundleToPublications < ActiveRecord::Migration[8.1]
  def change
    add_column :system_disk_image_publications, :uki_cosign_bundle, :text
  end
end
