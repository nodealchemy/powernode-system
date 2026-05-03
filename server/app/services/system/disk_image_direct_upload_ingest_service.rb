# frozen_string_literal: true

require "digest"
require "base64"
require "tempfile"

module System
  # Verifies a disk-image publication that was uploaded directly to the
  # account's FileStorageService backend (cloud-direct mode — S3/Azure/
  # GCS). The CI pipeline got a presigned PUT URL via /worker_api/
  # disk_image_publications/initiate, uploaded the bytes directly to
  # the storage backend, and then called /finalize. By the time this
  # service runs, the publication.file_object_id is already set.
  #
  # Returns a Result shaped identically to DiskImageOciIngestService so
  # the processor's downstream flow works for both modes.
  #
  # Verification steps:
  #   1. Stream the stored bytes through SHA-256, compare to publication.sha256.
  #   2. (Optional, if cosign trust is configured + signature payload provided)
  #      verify cosign signature.
  #   3. Stage a local tmp copy and return its path so the processor can
  #      use the same upload_to_storage! code path as OCI mode.
  #
  # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 2).
  class DiskImageDirectUploadIngestService
    Result = ::System::DiskImageOciIngestService::Result

    class << self
      def verify!(publication:)
        new.verify!(publication: publication)
      end
    end

    def verify!(publication:)
      return failure("publication required")           unless publication
      return failure("file_object required for direct-upload mode") if publication.file_object.blank?

      file_object = publication.file_object
      storage = ::FileStorageService.new(publication.account)

      # Stream-stage the stored bytes to a tmp file. This serves two
      # purposes: (1) lets us recompute SHA-256 without loading 1-4GB
      # into RAM, (2) gives the processor a local_path to feed back to
      # upload_to_storage! for consistent post-verify handling.
      local_path = stream_to_tmp(storage, file_object)
      actual_sha = Digest::SHA256.file(local_path).hexdigest

      if actual_sha != publication.sha256
        File.delete(local_path) if File.exist?(local_path)
        return failure("sha256 mismatch on uploaded file: expected=#{publication.sha256[0..15]}… actual=#{actual_sha[0..15]}…")
      end

      Result.new(
        ok?: true,
        local_path: local_path,
        cosign_bundle_b64: publication.cosign_bundle,
        attestation_bundle_b64: publication.attestation_bundle
      )
    rescue StandardError => e
      failure("direct-upload verify error: #{e.class}: #{e.message}")
    end

    private

    def failure(message)
      Result.new(ok?: false, error: message)
    end

    def stream_to_tmp(storage, file_object)
      tmp = Tempfile.new(["powernode-direct-upload-", ".img"])
      tmp.binmode
      storage.stream_file(file_object) do |chunk|
        tmp.write(chunk)
      end
      tmp.close
      tmp.path
    end
  end
end
