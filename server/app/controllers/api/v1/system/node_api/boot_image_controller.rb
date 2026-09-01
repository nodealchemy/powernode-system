# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Serves the standalone UKI artifact for an in-place boot-image upgrade
        # (campaign 019f505f increment 2). The agent, executing an
        # upgrade_boot_image task, GETs this to fetch the exact bytes it writes
        # to the ESP, then cosign-verifies them in STATIC-KEY mode against the
        # cosign_public_key and cosign_bundle_b64 carried inline in the task
        # options. (Not identity/issuer pins: those select cosign's KEYLESS mode,
        # which this platform's CI cannot produce a signature for.)
        #
        # The blob is proxied by DIGEST through OciBlobProxyService: the pull is
        # content-addressed (/v2/<repo>/blobs/<uki_sha256>), so the registry
        # cannot return wrong bytes for a given digest, and the first request per
        # digest caches to disk for the rest of the fleet. Scoped to the calling
        # instance's own platform — a node can only pull a UKI its own platform
        # published.
        #
        # PIN SOURCE (IMP-b55869029a57): the DiskImagePublication row, never the
        # NodePlatform.disk_image_uki_* columns. f2d0a32b unified the PLAN and
        # DISPATCH paths onto the promoted publication; this endpoint was a third,
        # still-divergent copy reading the columns, which made it authoritative on
        # BYTES while UpgradeDispatcher stayed authoritative on PINS. Two
        # consequences, both fatal on-node:
        #
        #   1. Any column-vs-publication skew (a partial-field promote writer)
        #      served bytes no task was ever pinned to, so EVERY boot-image
        #      upgrade died on "UKI sha256 mismatch" until the columns were
        #      repaired by hand.
        #   2. A promote landing between dispatch and download rewrote the columns
        #      under an in-flight task, killing every upgrade in that window.
        #
        # (2) needs the caller to say WHICH artifact it was pinned to, hence the
        # optional `digest` parameter. It is optional on purpose: the agent GETs
        # `download_path` verbatim out of its task options
        # (agent/internal/bootupgrade/bootupgrade.go download()), so the parameter
        # is reachable by having the dispatcher write the pinned digest into that
        # path — no agent change, no fleet rollout. Until it does, the
        # publication-backed default already closes (1).
        class BootImageController < BaseController
          UKI_MEDIA_TYPE = "application/vnd.powernode.uki.v1"

          # GET /api/v1/system/node_api/boot_image/download
          def download
            platform = current_node.node_platform
            return render_not_found("NodePlatform") if platform.nil?

            # A caller that sent the parameter but left it empty has a broken
            # pin — most likely the dispatcher serialized `?digest=` from a nil.
            # Treating that as "unpinned" would silently reinstate the
            # promote-window race the parameter exists to close, so refuse it
            # loudly instead of guessing.
            if params.key?(:digest) && requested_digest.nil?
              return render_error("digest parameter was supplied but empty", :bad_request)
            end

            publication = resolve_publication(platform)
            if publication.nil? || publication.uki_oci_ref.blank? || publication.uki_sha256.blank?
              return render_error(unresolved_message, :not_found)
            end

            uki_digest = publication.uki_sha256

            path = ::System::OciBlobProxyService.new(
              oci_ref:    publication.uki_oci_ref,
              media_type: UKI_MEDIA_TYPE,
              digest:     uki_digest,
              account:    current_account
            ).fetch_blob!

            response.headers["X-Boot-Image-Digest"] = uki_digest
            # The git sha of the artifact actually SERVED, not the platform's
            # current promotion — the agent records this as what it booted, and
            # during a promote window those are different builds.
            response.headers["X-Boot-Image-Git-SHA"] = publication.git_sha.to_s
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

          private

          # The UKI digest the caller was pinned to, normalized to the bare 64-hex
          # form DiskImagePublication#uki_sha256 stores (OciBlobProxyService and
          # the OCI spec both also write it `sha256:`-prefixed).
          def requested_digest
            @requested_digest ||= params[:digest].to_s.strip.delete_prefix("sha256:").downcase.presence
          end

          # Pinned request → that exact publication. Unpinned → the promoted one,
          # resolved the SAME way UpgradeDispatcher.preflight resolves it
          # (publications.find_by(git_sha: platform.disk_image_git_sha)) so the
          # bytes served and the pins dispatched cannot diverge.
          #
          # A pinned request that resolves nothing FAILS rather than falling back
          # to the promoted artifact: falling back is precisely the bug — handing
          # a node bytes its task was not pinned to, which it then rejects on
          # sha256 with no indication the platform substituted the artifact.
          def resolve_publication(platform)
            if requested_digest
              # Scoped to THIS platform's own history — not the account's, not
              # globally. A same-account sibling platform is a different arch or
              # a different image line, so serving across platforms hands a node
              # a UKI it cannot boot.
              #
              # `retainable` is published + retired, and RETIRED is load-bearing:
              # a promote retires the very row an in-flight task is pinned to.
              # But retired does NOT imply "was ever published" — the `retire`
              # AASM event also transitions from FAILED and VERIFYING
              # (disk_image_publication.rb) so DiskImageRetentionService#retire_stuck!
              # can clean up abandoned CI runs. That laundering path would make a
              # build which FAILED cosign/sha verification at ingest resolvable
              # by digest. published_at is the discriminator: only mark_published
              # and reactivate ever set it, never the failed/verifying → retired
              # path.
              return platform.disk_image_publications
                             .retainable.where.not(published_at: nil)
                             .find_by(uki_sha256: requested_digest)
            end

            return nil if platform.disk_image_git_sha.blank?

            # published_at is checked here for the SAME reason the digest branch
            # above checks it, and it is applied to BOTH the git_sha paths at
            # once: UpgradeDispatcher.preflight carries the identical guard
            # (IMP-80bd70c04afe). Scoping one without the other is the
            # plan-vs-dispatch divergence campaign 019f505f exists to kill —
            # dispatch pinning a row the download then refuses, or vice versa.
            #
            # Not `retainable` here, unlike the digest branch. That scope is
            # load-bearing THERE because an in-flight task must still fetch a row
            # a promote just retired. This branch resolves the CURRENT promotion,
            # not a historical pin, so it needs no such allowance — and a status
            # filter would newly refuse a retired-but-published row, which is
            # perfectly servable: the UKI is proxied from the OCI registry by
            # digest and never touches the soft-deleted file_object.
            #
            # No filter can change WHICH row this returns — (node_platform_id,
            # git_sha) is unique — only whether a row unfit to serve is returned
            # at all (IMP-fdaccb8e7c74).
            platform.disk_image_publications
                    .where.not(published_at: nil)
                    .find_by(git_sha: platform.disk_image_git_sha)
          end

          def unresolved_message
            if requested_digest
              "No UKI artifact matching digest #{requested_digest} published for this platform"
            else
              # Covers "no row for the promoted git_sha" AND "the row exists but
              # was never published" — the node's remedy is identical either way,
              # and the operator-facing distinction between them is drawn by
              # UpgradeDispatcher.platform_blocker (:pointer_inconsistent vs
              # :never_published), which is where an operator actually reads it.
              "No promoted UKI artifact for this platform"
            end
          end
        end
      end
    end
  end
end
