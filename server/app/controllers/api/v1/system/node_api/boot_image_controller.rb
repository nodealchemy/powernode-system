# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Serves the standalone UKI artifact for an in-place boot-image upgrade
        # (campaign 019f505f increment 2). The agent, executing an
        # upgrade_boot_image task, GETs this to fetch the exact bytes it writes
        # to the ESP, then cosign-verifies them against the identity/issuer pins
        # carried in the task options.
        #
        # The blob is proxied by DIGEST through OciBlobProxyService: the pull is
        # content-addressed (/v2/<repo>/blobs/<uki_sha256>), so the registry
        # cannot return wrong bytes for a given digest, and the first request per
        # digest caches to disk for the rest of the fleet. Scoped to the calling
        # instance's own platform — a node can only pull its platform's promoted
        # UKI.
        class BootImageController < BaseController
          UKI_MEDIA_TYPE = "application/vnd.powernode.uki.v1"

          # GET /api/v1/system/node_api/boot_image/download
          def download
            platform = current_node.node_platform
            return render_not_found("NodePlatform") if platform.nil?

            uki_ref    = platform.disk_image_uki_oci_ref
            uki_digest = platform.disk_image_uki_sha256
            if uki_ref.blank? || uki_digest.blank?
              return render_error("No promoted UKI artifact for this platform", :not_found)
            end

            path = ::System::OciBlobProxyService.new(
              oci_ref:    uki_ref,
              media_type: UKI_MEDIA_TYPE,
              digest:     uki_digest,
              account:    current_account
            ).fetch_blob!

            response.headers["X-Boot-Image-Digest"]  = uki_digest
            response.headers["X-Boot-Image-Git-SHA"] = platform.disk_image_git_sha.to_s
            response.headers["ETag"] = %("#{uki_digest}")
            send_file(
              path,
              type: "application/octet-stream",
              disposition: "attachment",
              # Cosmetic (the agent writes the arch's removable-boot name itself);
              # keep the header honest per arch.
              filename: current_instance.architecture.to_s == "arm64" ? "BOOTAA64.EFI" : "BOOTX64.EFI",
              stream: true,
              buffer_size: 65_536
            )
          rescue ::System::OciBlobProxyService::PullError => e
            ::Rails.logger.error("[BootImageController#download] UKI proxy failed: #{e.message}")
            render_error("UKI blob fetch failed: #{e.message}", :bad_gateway)
          end
        end
      end
    end
  end
end
