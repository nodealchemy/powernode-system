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
    # One authoritative artifact object name for BOTH publication modes.
    # The OCI-pull processor and the direct-upload initiate endpoint must
    # store under the same name, or the same (platform, git_sha, arch) build
    # lands at two different storage keys depending on how it arrived.
    # (IMP-c3007fd19bf3 — the direct-upload side previously called a helper
    # that was never defined anywhere.)
    def self.storage_filename_for(platform_name:, git_sha:, arch:)
      "#{platform_name}-#{git_sha.to_s[0..15]}-#{arch}.img"
    end

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
          # Transition-scoped `after`, NOT an event-level `before`
          # (IMP-6d2dd4533bd7) — identical shape and identical reasoning to
          # `reactivate` below: aasm 5.5.2 fires an event-level `before`
          # UNCONDITIONALLY, before the guard is checked (see `reactivate`'s
          # comment for the full trace through the gem source), so a
          # guard-failing mark_published (a :verifying row with no
          # file_object_id — e.g. a replayed webhook, or ingest failure
          # racing a save) would have stamped published_at/verified_at on
          # the in-memory object regardless, and
          # DiskImagePublicationProcessor#publish! calls
          # `publication.mark_published!` with its return value discarded,
          # inside a transaction that persists `publication` via other
          # writes in the same transaction.
          after { self.published_at = Time.current; self.verified_at ||= Time.current }
        end
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
          # Transition-scoped `after`, NOT an event-level `before` (IMP-6d2dd4533bd7).
          # Verified against aasm 5.5.2's actual source, not its docs:
          # aasm.rb#aasm_fire_event calls fire_default_callbacks — which fires
          # the event-level :before — UNCONDITIONALLY at line 102, BEFORE
          # event.may_fire? (the guard check) runs at line 104. So an
          # event-level `before` here would stamp published_at on the
          # in-memory object even when the guard fails, and the
          # call-and-discard idiom (`pub.reactivate; pub.save!`, used by
          # both PromotePublication and RollbackPublication) would persist
          # that stamp on a row that never actually left :retired.
          #
          # A transition-level `after` only fires from Transition#execute,
          # which event.rb's `_fire` calls exclusively inside the branch
          # where `transition.allowed?(obj)` — the guard — already returned
          # true. So this genuinely cannot apply unless the transition does.
          # (aasm 5.5.2's Transition DSL only recognizes :on_transition,
          # :guard, :after, :success — there is no transition-scoped
          # :before to move this to instead.)
          #
          # promotable? and UpgradeDispatcher.preflight both depend on
          # published_at being unforgeable by a failed transition — this is
          # the one place that invariant is actually enforced. See
          # promotable?'s comment below and preflight's :never_published
          # guard (boot_image/upgrade_dispatcher.rb).
          after { self.published_at = Time.current; self.retired_at = nil }
        end
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
        # Check EVERY platform pointing at these bytes, not just this row's own
        # (IMP-f0aad29b3344). The sweep below is deliberately unscoped — no
        # account, platform or status filter — and is followed by a PERMANENT
        # byte delete, so a guard that consults only self.node_platform is
        # narrower than the destruction it authorises. If one FileObject were
        # ever shared, purging platform A's retired row would pass this check
        # (A's pointer is elsewhere), nil out platform B's PUBLISHED row's
        # pointer, and hard-delete B's live boot image — with B's own
        # active-image check never consulted.
        #
        # WIDEN THE GUARD, DO NOT NARROW THE SWEEP. The reflex is backwards:
        # the sweep is CORRECT. Once the bytes are permanently gone, every
        # reference to them must be nil'd, cross-account included — a dangling
        # pointer to deleted bytes is strictly worse than a nil one. The defect
        # is the narrow guard, not the wide sweep. Cross-account for the same
        # reason: the deletion is cross-account, so the check must be.
        #
        # NOT REACHABLE TODAY, and this is insurance rather than a live fix:
        # nothing looks a FileObject up by digest (zero find_by/where on
        # checksum_sha256 in either app tree), every writer of
        # file_object_id takes a freshly minted upload
        # (DiskImagePublicationProcessor#upload_to_storage!, and worker_api's
        # signed_upload_url which mints one per call), and there is no
        # copy/clone path. But file_objects.checksum_sha256 carries a
        # NON-UNIQUE index with no reader — exactly what a "reuse the existing
        # blob" optimisation gets built on, and that optimisation would arm
        # this with no other change here.
        #
        # Deliberately NOT also refusing on a merely-published sibling
        # (`where(file_object_id: fo.id, status: "published")`): that would
        # change purge semantics for a case that cannot arise today, to protect
        # an unreachable one. The platform-pointer check is the boot-critical
        # one. Considered and declined.
        active_for = ::System::NodePlatform.where(disk_image_file_object_id: fo.id)
        if active_for.exists?
          raise "cannot purge #{id}: file_object #{fo.id} is the active disk image " \
                "for platform(s) #{active_for.pluck(:id).join(', ')}"
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
    # IMP-c3f186e56d5b: this closes a DIVERGENCE, not a novel guard.
    # BootImageController#resolve_publication already refuses this exact
    # state on both its lookup paths — `.retainable.where.not(published_at:
    # nil)` — specifically because `retired` is also reachable from
    # failed/verifying via DiskImageRetentionService#retire_stuck!, which
    # would otherwise make an unverified build resolvable
    # (boot_image_controller.rb:118-129). UpgradeDispatcher.preflight
    # carries the identical guard for the same reason (IMP-80bd70c04afe).
    # promotable? — the promote/rollback path — was the one site that did
    # not, so a laundered row was refused at serve time and at dispatch
    # time but still accepted at promote/rollback time: the exact
    # plan-vs-dispatch (here, promote-vs-serve) divergence campaign
    # 019f505f exists to eliminate.
    #
    # Adding published_at here is only sound as of IMP-6d2dd4533bd7: both
    # `mark_published` and `reactivate` used to stamp it via an event-level
    # `before`, which aasm fires BEFORE the transition guard is checked —
    # so a guard-failing transition could forge a published_at that would
    # have defeated this exact check. Verified by tracing the full
    # transition graph: no path lets a row carry published_at while in
    # :failed (mark_failed's from-list is %i[queued awaiting_upload
    # verifying], none of which can have gone through a successful
    # mark_published/reactivate), so published_at present + status failed
    # is structurally unreachable — published_at is sound here now.
    #
    # Three independent checks, all required:
    #   - status is :published or :retired — the two states this executor
    #     pair actually operates on (retired rows get reactivated back to
    #     published in the same transaction). Excludes :purged (see below).
    #   - file_object_id is present — the artifact bytes actually exist.
    #   - published_at is present — this row actually completed a
    #     mark_published/reactivate transition at some point; excludes a
    #     retire_stuck!-laundered row (status=retired, file_object_id
    #     present from a direct-upload that never passed verification,
    #     published_at nil because it never legitimately published).
    #
    # No single check is sufficient. `published_at` alone looks like the
    # obvious discriminator (only mark_published/reactivate ever set it,
    # nothing clears it) but purge! nils file_object_id and flips status →
    # :purged while leaving published_at (and the uki_* pins) untouched —
    # a purged row still reads as "was published" by that field alone, so
    # the status check still matters. And status+file_object_id alone is
    # the laundering gap this fix closes: a direct-upload publication can
    # carry a non-nil file_object_id while still :verifying (uploaded, not
    # yet cosign/sha verified — see
    # DiskImagePublicationProcessor#direct_upload_mode?), and that same
    # unverified file_object_id survives an unattended retire_stuck! sweep
    # into :retired.
    def promotable?
      file_object_id.present? && status.in?(%w[published retired]) && published_at.present?
    end
  end
end
