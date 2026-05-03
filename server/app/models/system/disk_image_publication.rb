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
  #   retired  → purged        (reaper grace expired — hard-delete file_object)
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
        transitions from: :published, to: :retired
        before { self.retired_at = Time.current }
      end

      event :purge do
        transitions from: :retired, to: :purged
        before { self.purged_at = Time.current }
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
    def purge!(deleted_by_user: nil)
      if file_object_id.present?
        ::FileStorageService.new(account)
                            .delete_file(file_object, permanent: true, deleted_by_user: deleted_by_user)
      end
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
  end
end
