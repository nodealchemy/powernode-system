# frozen_string_literal: true

module System
  # Serializer for DiskImagePublication. Includes everything the
  # operator UI needs to render a history row:
  #   - status + state-derived flags (active, retired, purged)
  #   - identification: git_sha, sha256 (truncated), oci_ref, arch, firmware_ref
  #   - lifecycle timestamps
  #   - attestation predicate (decoded JSON for inline display)
  #   - prior_file_object_id (for rollback chain visualization)
  #
  # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 3).
  class DiskImagePublicationSerializer
    def initialize(publication)
      @publication = publication
    end

    def as_json
      {
        id:                       @publication.id,
        platform_id:              @publication.node_platform_id,
        account_id:               @publication.account_id,
        status:                   @publication.status,
        active:                   @publication.active?,
        git_sha:                  @publication.git_sha,
        git_sha_short:            @publication.git_sha&.[](0..7),
        sha256:                   @publication.sha256,
        sha256_short:             @publication.sha256&.[](0..15),
        oci_ref:                  @publication.oci_ref,
        size_bytes:               @publication.size_bytes,
        firmware_ref:             @publication.firmware_ref,
        arch:                     @publication.arch,
        attempt_count:            @publication.attempt_count,
        attestation_predicate:    @publication.cosign_attestation_predicate,
        attestation_present:      @publication.attestation_bundle.present?,
        cosign_bundle_present:    @publication.cosign_bundle.present?,
        file_object_id:           @publication.file_object_id,
        prior_file_object_id:     @publication.prior_file_object_id,
        webhook_id:               @publication.webhook_id,
        webhook_label:            @publication.webhook&.label,
        triggered_by_worker_id:   @publication.triggered_by_worker_id,
        error_message:            @publication.error_message,
        verified_at:              @publication.verified_at,
        published_at:             @publication.published_at,
        retired_at:               @publication.retired_at,
        purged_at:                @publication.purged_at,
        created_at:               @publication.created_at,
        updated_at:               @publication.updated_at
      }
    end
  end
end
