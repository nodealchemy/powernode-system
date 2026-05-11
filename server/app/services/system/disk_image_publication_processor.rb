# frozen_string_literal: true

module System
  # Runs the post-webhook chain for a disk-image publication:
  # idempotency check → ingest (cosign verify + OCI pull or
  # direct-upload verify) → upload bytes to FileStorageService →
  # update DiskImagePublication + NodePlatform pointer atomically →
  # emit FleetEvent → enqueue retention sweep.
  #
  # Mirrors the System::ModulePublicationProcessor result-object
  # pattern exactly so operators see one mental model. Unlike module
  # publication, the publication row already exists when this runs
  # (created by the webhook receiver) so this processor is a state-
  # transition driver rather than a record creator.
  #
  # Each side effect is independently non-fatal: ingest failure flips
  # status → :failed and emits system.disk_image_publish_failed,
  # surfacing in FleetDashboard. FileStorageService failures bubble
  # up to the worker job's retry budget. The DB transaction wrapping
  # publication + platform updates ensures we never end up with a
  # half-updated platform pointing at a non-existent FileObject.
  #
  # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 2).
  class DiskImagePublicationProcessor
    Result = Struct.new(:ok?, :error, :publication, :file_object,
                        :idempotent_hit, keyword_init: true)

    class << self
      def process!(publication:)
        new.process!(publication: publication)
      end
    end

    def process!(publication:)
      return failure(nil, "publication required") unless publication
      return idempotent_hit!(publication) if already_published?(publication)

      publication.update!(attempt_count: publication.attempt_count + 1)
      publication.start_verifying!

      ingest = run_ingest!(publication)
      return mark_failed!(publication, ingest.error) unless ingest.success?

      file_object = upload_to_storage!(publication, ingest.local_path)
      publish!(publication, file_object, ingest)
      enqueue_retention_sweep(publication.node_platform)

      Result.new(ok?: true, publication: publication, file_object: file_object)
    rescue ::ActiveRecord::RecordInvalid, ::ActiveRecord::RecordNotSaved => e
      mark_failed!(publication, "DB invariant violation: #{e.message}")
    ensure
      cleanup_local_file(ingest)
    end

    private

    def failure(publication, message)
      Result.new(ok?: false, error: message, publication: publication)
    end

    # Short-circuit: when the same git_sha has already published
    # successfully, re-receives are no-ops. Re-runs against the same
    # SHA after a partial failure DO retry (status != published).
    def already_published?(publication)
      publication.published? && publication.file_object_id.present?
    end

    def idempotent_hit!(publication)
      Result.new(ok?: true, publication: publication,
                 file_object: publication.file_object,
                 idempotent_hit: true)
    end

    # Selects the right ingest adapter based on the publication source.
    # Direct-upload mode (cloud installs) uses the file_object_id that
    # was set at /worker_api/disk_image_publications/initiate time;
    # OCI-pull mode (default) downloads via oras + verifies cosign.
    def run_ingest!(publication)
      if direct_upload_mode?(publication)
        ::System::DiskImageDirectUploadIngestService.verify!(publication: publication)
      else
        ::System::DiskImageOciIngestService.verify_and_pull!(publication: publication)
      end
    end

    # Direct-upload publications come in with file_object_id pre-set
    # (the operator's CI runner did `PUT $signed_upload_url` first,
    # then called /finalize). OCI-pull publications enter with
    # oci_ref set and no file_object yet.
    def direct_upload_mode?(publication)
      publication.file_object_id.present? && publication.oci_ref.blank?
    end

    # Streams the verified local file into the account's
    # FileStorageService. The service handles backend selection
    # (local/S3/Azure/GCS/NFS/SMB) and SHA-256 verification on its
    # side too — matching our independent SHA check during ingest.
    def upload_to_storage!(publication, local_path)
      storage = ::FileStorageService.new(publication.account)
      # FileObject.belongs_to :uploaded_by is required. CI-triggered
      # uploads don't have a User context, so attribute to the account's
      # owner/admin (whichever exists). The DiskImagePublication carries
      # triggered_by_worker for the full audit trail.
      # NOTE: FileStorageService.upload_file expects `uploaded_by_id`
      # (singular id), not the User object (`uploaded_by:`).
      uploader = publication.account.users.first
      File.open(local_path, "rb") do |io|
        storage.upload_file(io,
          filename:        storage_filename(publication),
          content_type:    "application/octet-stream",
          category:        "disk_image",
          uploaded_by_id:  uploader&.id
        )
      end
    end

    def storage_filename(publication)
      "#{publication.node_platform.name}-#{publication.git_sha[0..15]}-#{publication.arch}.img"
    end

    # Atomic: publication state + platform pointer flip in one transaction.
    # Captures prior_file_object_id BEFORE the platform update so rollback
    # can restore it without ambiguity.
    def publish!(publication, file_object, ingest)
      prior_id = publication.node_platform.disk_image_file_object_id

      ::ApplicationRecord.transaction do
        publication.assign_attributes(
          file_object_id: file_object.id,
          prior_file_object_id: prior_id,
          cosign_bundle:      ingest.respond_to?(:cosign_bundle_b64) ? ingest.cosign_bundle_b64 : nil,
          attestation_bundle: ingest.respond_to?(:attestation_bundle_b64) ? ingest.attestation_bundle_b64 : nil
        )
        publication.mark_published!

        publication.node_platform.update!(
          disk_image_file_object_id:     file_object.id,
          disk_image_sha256:             publication.sha256,
          disk_image_size_bytes:         publication.size_bytes,
          disk_image_built_at:           publication.published_at,
          disk_image_oci_ref:            publication.oci_ref,
          disk_image_git_sha:            publication.git_sha,
          disk_image_publication_status: "published",
          disk_image_publication_error:  nil
        )
      end

      emit_published_event(publication, prior_id)
    end

    def mark_failed!(publication, error_message)
      publication.mark_failed!(error_message)
      publication.node_platform.update_columns(
        disk_image_publication_status: "failed",
        disk_image_publication_error:  error_message,
        updated_at:                    Time.current
      )
      emit_publish_failed_event(publication, error_message)
      Result.new(ok?: false, error: error_message, publication: publication)
    rescue StandardError => e
      Rails.logger.warn "[DiskImagePublicationProcessor] mark_failed cleanup raised: #{e.class}: #{e.message}"
      Result.new(ok?: false, error: error_message, publication: publication)
    end

    # Schedules a retention sweep so old publications get retired on
    # the next worker tick. The reaper job runs daily anyway, but
    # triggering on-publish keeps history compact between runs.
    def enqueue_retention_sweep(platform)
      return unless defined?(::WorkerApiClient)
      ::WorkerApiClient.new.queue_disk_image_retention_sweep(platform_id: platform.id)
    rescue StandardError => e
      Rails.logger.info "[DiskImagePublicationProcessor] retention sweep enqueue skipped: #{e.class}: #{e.message}"
    end

    def emit_published_event(publication, prior_file_object_id)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account:  publication.account,
        kind:     "system.disk_image_published",
        severity: :low,
        source:   publication.webhook_id ? "gitea_webhook" : "ci_pipeline_direct",
        payload: {
          publication_id:        publication.id,
          platform_id:           publication.node_platform_id,
          platform_name:         publication.node_platform.name,
          git_sha:               publication.git_sha,
          oci_ref:               publication.oci_ref,
          sha256:                publication.sha256,
          size_bytes:            publication.size_bytes,
          firmware_ref:          publication.firmware_ref,
          arch:                  publication.arch,
          prior_file_object_id:  prior_file_object_id,
          attestation_predicate: publication.cosign_attestation_predicate
        }
      )
    rescue StandardError => e
      Rails.logger.warn "[DiskImagePublicationProcessor] published event emit failed: #{e.class}: #{e.message}"
    end

    def emit_publish_failed_event(publication, error_message)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account:  publication.account,
        kind:     "system.disk_image_publish_failed",
        severity: :high,
        source:   publication.webhook_id ? "gitea_webhook" : "ci_pipeline_direct",
        payload: {
          publication_id: publication.id,
          platform_id:    publication.node_platform_id,
          platform_name:  publication.node_platform.name,
          git_sha:        publication.git_sha,
          oci_ref:        publication.oci_ref,
          arch:           publication.arch,
          attempt_count:  publication.attempt_count,
          error:          error_message
        }
      )
    rescue StandardError => e
      Rails.logger.warn "[DiskImagePublicationProcessor] failed event emit failed: #{e.class}: #{e.message}"
    end

    def cleanup_local_file(ingest)
      return unless ingest.respond_to?(:local_path) && ingest.local_path
      return unless File.exist?(ingest.local_path)

      File.delete(ingest.local_path)
    rescue StandardError
      # best-effort temp file cleanup; not worth raising on
    end
  end
end
