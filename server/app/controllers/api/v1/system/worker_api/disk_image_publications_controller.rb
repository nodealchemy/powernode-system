# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-side endpoint family for disk-image publications:
        #
        #   POST /worker_api/disk_image_publications/process
        #     — Long-pole work for an OCI-pull or post-finalize publication.
        #     Called by System::ProcessDiskImagePublicationJob.
        #
        #   POST /worker_api/disk_image_publications/initiate
        #     — Cloud-direct mode only. CI runner calls this first;
        #     receives a presigned PUT URL + publication_id. Then PUTs
        #     bytes directly to the storage backend.
        #
        #   POST /worker_api/disk_image_publications/finalize
        #     — Cloud-direct mode only. CI runner calls this after the
        #     direct upload. Triggers verify + processor.
        #
        #   POST /worker_api/disk_image_publications/sweep_retention
        #     — Called by System::ExpireOldDiskImageFileObjectsJob.
        #     Iterates an account's platforms, retires + purges per
        #     platform.disk_image_retention_count. When called account-wide
        #     (no platform_id, the only mode the daily job uses) also runs
        #     the DK3 stuck-cleanup sweep (retire_stuck!) so publications
        #     abandoned mid-verify don't strand forever.
        #
        # All four enforce worker.account_id == publication.account_id
        # (or platform.account_id for the sweep) so a leaked CI worker
        # token can never reach across accounts.
        #
        # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 2).
        class DiskImagePublicationsController < BaseController
          # POST /worker_api/disk_image_publications/process
          # Body: { publication_id }
          def process_publication
            authorize_worker_permission!("system.platforms.publish_disk_image")

            publication = ::System::DiskImagePublication.find_by(id: params[:publication_id])
            return render_not_found("DiskImagePublication") unless publication
            return render_forbidden("worker account mismatch") unless current_worker.account_id == publication.account_id

            publication.update_columns(triggered_by_worker_id: current_worker.id, updated_at: Time.current)

            result = ::System::DiskImagePublicationProcessor.process!(publication: publication)

            if result.ok?
              render_success(data: {
                publication_id:     publication.id,
                file_object_id:     result.file_object&.id,
                idempotent_hit:     !!result.idempotent_hit,
                platform_id:        publication.node_platform_id,
                git_sha:            publication.git_sha,
                publication_status: publication.reload.status
              })
            else
              # 422: validation-class failure (don't retry); transient errors
              # come back from the ingest service as :error => "..." and DO
              # retry — Sidekiq's retry middleware treats any non-2xx as
              # retryable.
              render_error(result.error, 422,
                           details: { publication_id: publication.id })
            end
          end

          # POST /worker_api/disk_image_publications/initiate
          # Body: { platform_name, sha256, size_bytes, git_sha, arch, firmware_ref? }
          # Returns: { publication_id, signed_upload_url, upload_expires_at }
          def initiate
            authorize_worker_permission!("system.platforms.publish_disk_image")

            platform = current_worker.account.system_node_platforms.find_by(name: params[:platform_name])
            return render_not_found("NodePlatform") unless platform

            unless platform.cosign_trust_configured?
              return render_error("platform '#{platform.name}' has no cosign trust policy — operator must configure cosign_identity_regexp + cosign_issuer_regexp before direct-upload mode is allowed", 422)
            end

            storage = ::FileStorageService.new(current_worker.account)
            unless storage.storage_supports_direct_upload?
              return render_error(
                "Storage backend does not support presigned uploads. Use OCI-pull mode (the disk-image webhook) instead, or migrate this account to S3/Azure/GCS.",
                422
              )
            end

            publication = ::System::DiskImagePublication.find_or_initialize_by(
              node_platform: platform, git_sha: params[:git_sha].to_s
            )
            if publication.published?
              return render_success(data: {
                publication_id: publication.id,
                idempotent_hit: true,
                note: "already published with this git_sha; no new upload needed"
              })
            end

            upload = storage.signed_upload_url(
              category:           "disk_image",
              filename:           direct_upload_filename(platform, params[:git_sha].to_s, params[:arch].to_s),
              content_type:       "application/octet-stream",
              expected_sha256:    params.require(:sha256),
              expected_size_bytes: params.require(:size_bytes).to_i,
              expires_in:         1.hour,
              uploaded_by:        nil # Worker is not a User; FileObject.uploaded_by remains nil
            )

            publication.assign_attributes(
              account:                current_worker.account,
              file_object_id:         upload[:file_object_id],
              sha256:                 params.require(:sha256),
              size_bytes:             params.require(:size_bytes).to_i,
              arch:                   params[:arch].presence || "arm64",
              firmware_ref:           params[:firmware_ref],
              payload:                params.to_unsafe_h.except(:controller, :action),
              triggered_by_worker_id: current_worker.id,
              status:                 "awaiting_upload",
              **stale_artifact_provenance_reset
            )
            publication.save!

            render_success(data: {
              publication_id:    publication.id,
              file_object_id:    upload[:file_object_id],
              signed_upload_url: upload[:upload_url],
              upload_expires_at: upload[:upload_expires_at]
            })
          rescue ::FileStorageService::NotSupportedError,
                 ::FileStorageService::StorageNotFoundError => e
            # StorageNotFoundError raises from FileStorageService#initialize
            # when the account has no storage configuration — same operator
            # remedy as NotSupportedError, so same 422 (a 500 here would make
            # Sidekiq retry a call that can never succeed until an operator
            # configures storage).
            render_error(e.message, 422)
          end

          # POST /worker_api/disk_image_publications/finalize
          # Body: { publication_id, sha256_verify }
          def finalize
            authorize_worker_permission!("system.platforms.publish_disk_image")

            publication = ::System::DiskImagePublication.find_by(id: params[:publication_id])
            return render_not_found("DiskImagePublication") unless publication
            return render_forbidden("worker account mismatch") unless current_worker.account_id == publication.account_id
            unless publication.awaiting_upload?
              return render_error("publication is not in awaiting_upload state (current=#{publication.status})", 422)
            end

            sha_verify = params[:sha256_verify].to_s
            if sha_verify != publication.sha256
              return render_error("sha256_verify (#{sha_verify[0..15]}...) does not match expected (#{publication.sha256[0..15]}...)", 422)
            end

            publication.update_columns(triggered_by_worker_id: current_worker.id, updated_at: Time.current)
            result = ::System::DiskImagePublicationProcessor.process!(publication: publication)

            if result.ok?
              render_success(data: {
                publication_id:     publication.id,
                file_object_id:     result.file_object&.id,
                platform_id:        publication.node_platform_id,
                publication_status: publication.reload.status
              })
            else
              render_error(result.error, 422,
                           details: { publication_id: publication.id })
            end
          end

          # POST /worker_api/disk_image_publications/sweep_retention
          # Body: { platform_id? } — if absent, sweeps all platforms for this account.
          # Called by System::ExpireOldDiskImageFileObjectsJob (cron daily).
          def sweep_retention
            authorize_worker_permission!("system.platforms.publish_disk_image")

            grace_days = (params[:grace_days] || ::System::DiskImageRetentionService::DEFAULT_GRACE_DAYS).to_i

            if params[:platform_id].present?
              platform = current_worker.account.system_node_platforms.find_by(id: params[:platform_id])
              return render_not_found("NodePlatform") unless platform
              result = ::System::DiskImageRetentionService.sweep!(platform: platform, grace_days: grace_days)
              render_success(data: { platform_id: platform.id, retired: result.retired_count, purged: result.purged_count })
            else
              # DK3: this is the only branch System::ExpireOldDiskImageFileObjectsJob
              # exercises (it POSTs with no platform_id). sweep_account! alone only
              # handles the published→retired→purged GC path — a publication
              # stranded in :verifying/:failed by a crashed worker or an ingest
              # error was never reaped by anything on the daily cron. Run the
              # DK3 stuck-cleanup sweep here too so those rows retire, then flow
              # into the normal purge on a later grace-expired sweep.
              stuck = ::System::DiskImageRetentionService.retire_stuck!(account: current_worker.account, grace_days: grace_days)
              per_platform = ::System::DiskImageRetentionService.sweep_account!(account: current_worker.account, grace_days: grace_days)
              summary = per_platform.transform_values { |r| { retired: r.retired_count, purged: r.purged_count } }
              render_success(data: { account_id: current_worker.account_id, per_platform: summary, stuck_retired: stuck.retired_count })
            end
          end

          private

          # Storage object name for a direct-upload artifact. Delegates to the
          # model's single authority so both publication modes (OCI pull via
          # DiskImagePublicationProcessor, direct upload here) store the same
          # build under the same key. The arch default mirrors the
          # assign_attributes default below. (IMP-c3007fd19bf3: this method
          # was called since 0fb034c6 but never defined — every #initiate
          # 500'd with NameError.)
          def direct_upload_filename(platform, git_sha, arch)
            ::System::DiskImagePublication.storage_filename_for(
              platform_name: platform.name,
              git_sha:       git_sha,
              arch:          arch.presence || "arm64"
            )
          end

          # IMP-c3f186e56d5b (source fix). find_or_initialize_by(node_platform,
          # git_sha) in #initiate reuses an EXISTING row whenever the same
          # git_sha is re-submitted for direct upload — legitimate, e.g. a
          # rebuilt CI run. The `publication.published?` guard only refuses
          # reuse while the row is CURRENTLY published; a row that was
          # published then later retired (rollback, or the reaper) is fair
          # game, and its status then resets BACKWARD to "awaiting_upload"
          # — off the normal AASM graph; no transition reaches
          # :awaiting_upload from :retired.
          #
          # #initiate's file_object_id is reassigned to a brand-new,
          # UNVERIFIED upload. Every OTHER column that describes that OLD
          # artifact or its lifecycle must reset with it, or it survives as
          # a stale claim about bytes this row no longer points at.
          # promotable? (disk_image_publication.rb), BootImageController's
          # two lookup branches, and UpgradeDispatcher.preflight all read
          # published_at (and preflight + the digest branch also read the
          # uki_* pins) as evidence this row's CURRENT artifact was
          # verified — that was never true for these columns; they only
          # ever proved the ROW was published at some point, which is a
          # different claim once the row's file_object_id can change under
          # it.
          #
          # Row IDENTITY (account, node_platform, git_sha, created_at,
          # attempt_count) is untouched — this is still the same
          # publication-history entry, and attempt_count is a monotonic
          # counter incremented elsewhere (DiskImagePublicationProcessor),
          # not artifact provenance.
          def stale_artifact_provenance_reset
            {
              # THE column IMP-c3f186e56d5b was filed against: the
              # discriminator promotable?, preflight, and both
              # BootImageController branches all key off.
              published_at:        nil,
              # Set alongside published_at by mark_published; same claim,
              # same staleness.
              verified_at:         nil,
              # Describes when the OLD artifact was retired — meaningless
              # for a row now back in :awaiting_upload for a new one.
              retired_at:          nil,
              # Defensive: find_or_initialize_by has no status filter, so a
              # :purged row (bytes hard-deleted) is technically reusable
              # too. Its purged_at must not survive to a re-live row.
              purged_at:           nil,
              # Describes why the OLD verification attempt failed;
              # irrelevant to (and misleading about) the new one.
              error_message:       nil,
              # OCI-registry UKI pins for the OLD build. Left in place,
              # boot_image_controller.rb's digest branch
              # (`find_by(uki_sha256: requested_digest)`) could resolve an
              # in-flight node's request to the OLD, verified digest while
              # this row's actual bytes (file_object_id) are the NEW,
              # unverified upload — serving correct-looking bytes for the
              # wrong, unverified row.
              uki_oci_ref:         nil,
              uki_sha256:          nil,
              uki_cosign_bundle:   nil,
              # Cosign attestation/signature bundles over the OLD .img
              # bytes — do not describe the new file_object_id.
              attestation_bundle:  nil,
              cosign_bundle:       nil,
              # Boot-pointer lineage from the OLD publish event (what the
              # platform pointed at immediately before THAT promote). Not
              # meaningful for an artifact that was never promoted.
              prior_file_object_id: nil,
              # Source OCI artifact ref from a PRIOR OCI-pull-mode publish.
              # DiskImagePublicationProcessor#direct_upload_mode? requires
              # oci_ref.blank? to route this row through the direct-upload
              # ingest adapter — a stale oci_ref here would misroute this
              # row's verification through the OCI-pull adapter instead, a
              # functional bug layered on top of the trust one.
              oci_ref:             nil
            }
          end
        end
      end
    end
  end
end
