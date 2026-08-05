# frozen_string_literal: true

module System
  # Append-only history of disk-image publications. One row per CI build
  # (uniqued on `(node_platform_id, git_sha)`). Three jobs:
  #
  #   1. Idempotency anchor — re-received webhooks for the same git_sha
  #      hit the existing row and short-circuit if already published.
  #   2. Rollback substrate — operator can pick any prior :published row
  #      and re-activate it (flips NodePlatform.disk_image_file_object_id
  #      back).
  #   3. Reaper boundary — the retention sweep operates on this table.
  #      Older builds stay visible in operator history (status :retired)
  #      until purged_at is set (status :purged) past the grace window.
  #
  # State machine (AASM, mirrors the convention in System::Task):
  #
  #   queued → awaiting_upload (cloud-direct mode)
  #          → verifying       (OCI-pull mode after worker picks up)
  #   verifying → published    (success — emits FleetEvent, flips platform pointer)
  #             → failed       (cosign/sha mismatch — emits failed event)
  #   published → retired      (reaper — soft-delete file_object, retain row)
  #   failed, verifying → retired (DK3 cleanup rake — abandoned/stuck builds
  #                                past a grace window, same terminal state)
  #   retired  → purged        (reaper grace expired — hard-delete file_object)
  #   retired  → published    (reactivate — operator rollback/promote, restores file_object)
  #
  # `attempt_count` increments on each re-receive so operators can see
  # which publications had transient failures before settling.
  #
  # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 1).
  class DiskImagePublication < BaseRecord
    include AASM

    self.table_name = "system_disk_image_publications"

    STATUSES = %w[queued awaiting_upload verifying published failed retired purged].freeze
    ARCHES   = %w[amd64 arm64].freeze

    belongs_to :account
    belongs_to :node_platform, class_name: "System::NodePlatform"
    belongs_to :file_object, class_name: "FileManagement::Object", optional: true
    belongs_to :prior_file_object, class_name: "FileManagement::Object", optional: true
    belongs_to :webhook, class_name: "System::DiskImageWebhook", optional: true
    belongs_to :triggered_by_worker, class_name: "Worker", optional: true

    validates :status, inclusion: { in: STATUSES }
    validates :git_sha, presence: true
    validates :sha256, presence: true, format: { with: /\A[a-f0-9]{64}\z/, message: "must be 64 hex chars" }
    # Standalone UKI artifact (campaign 019f505f inc 2). Optional — publications
    # built before the UKI-publishing CI (and the cloud-direct path) carry none.
    validates :uki_sha256, format: { with: /\A[a-f0-9]{64}\z/, message: "must be 64 hex chars" }, allow_nil: true
    validates :size_bytes, presence: true, numericality: { greater_than: 0 }
    validates :arch, inclusion: { in: ARCHES }
    validates :git_sha, uniqueness: { scope: :node_platform_id, message: "already published for this platform" }

    # ── Scopes ──────────────────────────────────────────────────────────
    scope :published_state, -> { where(status: "published") }
    scope :retainable,      -> { where(status: %w[published retired]) }
    scope :purgeable,       ->(grace_days: 7) { where(status: "retired").where("retired_at < ?", grace_days.days.ago) }
    scope :recent_for,      ->(platform, n = 10) { where(node_platform: platform).order(created_at: :desc).limit(n) }

    # ── State machine ──────────────────────────────────────────────────
    aasm column: :status, whiny_transitions: false do
      state :queued, initial: true
      state :awaiting_upload
      state :verifying
      state :published
      state :failed
      state :retired
      state :purged

      event :await_upload do
        transitions from: :queued, to: :awaiting_upload
      end

      event :start_verifying do
        transitions from: %i[queued awaiting_upload verifying failed], to: :verifying
      end

      event :mark_published do
        transitions from: :verifying, to: :published do
          guard { file_object_id.present? }
        end
        before { self.published_at = Time.current; self.verified_at ||= Time.current }
      end

      event :mark_failed do
        transitions from: %i[queued awaiting_upload verifying], to: :failed
        before { |error| self.error_message = error.to_s if error }
      end

      event :retire do
        # DK3: also reachable from :failed / :verifying so the stuck-publication
        # cleanup rake can retire abandoned CI runs (crashed worker mid-verify,
        # or a build that failed and was never retried) — not just the normal
        # published → retired reaper path. Same terminal state either way; a
        # retired row still carries its history and flows into the existing
        # purgeable scope once its own grace window elapses.
        transitions from: %i[published failed verifying], to: :retired
        before { self.retired_at = Time.current }
      end

      event :purge do
        transitions from: :retired, to: :purged
        before { self.purged_at = Time.current }
      end

      # Dedicated event for RollbackPublication/PromotePublication reactivating
      # a retired target — deliberately separate from `mark_published` (which
      # the CI/webhook ingest pipeline also drives via DiskImagePublicationProcessor)
      # so broadening the operator rollback path can never let a replayed
      # webhook re-publish an already-retired git_sha. Without this transition
      # the row stays status=retired after the platform pointer flips back to
      # it, and the next purge sweep would treat the now-active image as
      # purgeable (see IMP-d4a546024745).
      event :reactivate do
        transitions from: :retired, to: :published do
          guard { file_object_id.present? }
        end
        before { self.published_at = Time.current; self.retired_at = nil }
      end
    end

    # ── Convenience helpers (used by reaper + processor) ────────────────

    # Soft-delete the FileObject + flip status to :retired in one shot.
    # Caller (DiskImageRetentionService) wraps in a transaction.
    def retire!(deleted_by_user: nil)
      if file_object_id.present?
        ::FileStorageService.new(account)
                            .delete_file(file_object, permanent: false, deleted_by_user: deleted_by_user)
      end
      retire
      save!
    end

    # Hard-delete the FileObject + flip status to :purged.
    #
    # Two FKs reference file_objects: our own file_object_id AND any
    # successor publication's prior_file_object_id (set at publish time so
    # rollback can restore the previous pointer). Both must be cleared
    # BEFORE the hard-delete or PG raises ActiveRecord::InvalidForeignKey
    # (fk_rails_416646d33d) and the row never reaches :purged — quota is
    # never reclaimed.
    def purge!(deleted_by_user: nil)
      fo = file_object
      if fo
        if fo.id == node_platform.disk_image_file_object_id
          raise "cannot purge #{id}: file_object #{fo.id} is the platform's active disk image"
        end

        ::ApplicationRecord.transaction do
          self.class.where(prior_file_object_id: fo.id).update_all(prior_file_object_id: nil)
          self.class.where(file_object_id: fo.id).update_all(file_object_id: nil)
        end
        self.file_object_id = nil

        ::FileStorageService.new(account)
                            .delete_file(fo, permanent: true, deleted_by_user: deleted_by_user)
      end
      # The UKI pins are a SEPARATE artifact from file_object — OCI-registry-
      # hosted, served via OciBlobProxyService, never touched by the
      # FileStorageService hard-delete above. Left in place they read as
      # "this row still has a servable UKI" to any reader that checks only
      # published_at / uki_* presence and not status — which is exactly what
      # UpgradeDispatcher.preflight did (IMP-6c366751ddbd): a purged row kept
      # planning GREEN because published_at and the uki_* pins both survive
      # purge untouched. preflight itself now also refuses on `purged?`
      # directly (the actual fix — it does not depend on these being nil),
      # but clearing them here is defense in depth for every OTHER current
      # or future reader of these columns that doesn't separately check
      # status (e.g. BootImageController#resolve_publication's unparameterized
      # fallback branch has the identical published_at-only gap). Does NOT
      # retroactively repair rows purged before this shipped — no backfill
      # migration accompanies this change.
      self.uki_oci_ref = nil
      self.uki_sha256 = nil
      self.uki_cosign_bundle = nil
      purge
      save!
    end

    # Decoded attestation predicate for UI display. Returns nil if no
    # attestation_bundle is present (e.g. older publications from before
    # attestation was added).
    def cosign_attestation_predicate
      return nil if attestation_bundle.blank?

      ::JSON.parse(::Base64.strict_decode64(attestation_bundle))
    rescue StandardError
      nil
    end

    # True when this publication is the platform's currently-active one.
    def active?
      published? && node_platform.disk_image_file_object_id == file_object_id
    end

    # True when it is safe for PromotePublication/RollbackPublication to
    # point the platform's boot pointer at this row.
    #
    # Two independent checks, both required:
    #   - status is :published or :retired — the two states this executor
    #     pair actually operates on (retired rows get reactivated back to
    #     published in the same transaction).
    #   - file_object_id is present — the artifact bytes actually exist.
    #
    # Neither check alone is sufficient. `published_at` looks like the
    # obvious single-field discriminator (only mark_published/reactivate
    # ever set it, nothing clears it) but purge! nils file_object_id and
    # flips status → :purged while leaving published_at (and the uki_*
    # pins) untouched — a purged row still reads as "was published" by
    # that field alone. And status alone isn't enough either: a
    # direct-upload publication can carry a non-nil file_object_id while
    # still :verifying (uploaded, not yet cosign/sha verified) — see
    # DiskImagePublicationProcessor#direct_upload_mode?.
    def promotable?
      file_object_id.present? && status.in?(%w[published retired])
    end
  end
end
