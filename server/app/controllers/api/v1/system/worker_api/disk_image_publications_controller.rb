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
        #     platform.disk_image_retention_count.
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
              status:                 "awaiting_upload"
            )
            publication.save!

            render_success(data: {
              publication_id:    publication.id,
              file_object_id:    upload[:file_object_id],
              signed_upload_url: upload[:upload_url],
              upload_expires_at: upload[:upload_expires_at]
            })
          rescue ::FileStorageService::NotSupportedError => e
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
              per_platform = ::System::DiskImageRetentionService.sweep_account!(account: current_worker.account, grace_days: grace_days)
              summary = per_platform.transform_values { |r| { retired: r.retired_count, purged: r.purged_count } }
              render_success(data: { account_id: current_worker.account_id, per_platform: summary })
            end
          end
        end
      end
    end
  end
end
