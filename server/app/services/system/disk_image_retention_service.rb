# frozen_string_literal: true

module System
  # Per-platform disk-image retention sweep. Two-stage lifecycle keeps
  # rollback possible during the grace window:
  #
  #   1. RETIRE: keep the newest N published publications, transition
  #      older ones to :retired (file_object soft-deleted via
  #      FileStorageService.delete_file permanent: false). Operator
  #      can still rollback to a retired publication during the grace
  #      window — file_object is soft-deleted, restorable.
  #
  #   2. PURGE: retired publications past the grace window
  #      (default 7 days) get hard-deleted (file_object removed
  #      permanently from storage backend). Status flips to :purged.
  #      Rollback to a purged publication is rejected by the operator
  #      controller.
  #
  # Invocation:
  #   - DiskImagePublicationProcessor enqueues this on every successful
  #     publish (so history compacts immediately, not just at cron tick).
  #   - System::ExpireOldDiskImageFileObjectsJob runs daily at 3:30 AM
  #     UTC as a safety net for missed enqueue paths.
  #
  # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 2).
  class DiskImageRetentionService
    Result = Struct.new(:retired_count, :purged_count, :errors, keyword_init: true)

    DEFAULT_GRACE_DAYS = 7

    class << self
      def sweep!(platform:, grace_days: DEFAULT_GRACE_DAYS, deleted_by_user: nil)
        new.sweep!(platform: platform, grace_days: grace_days, deleted_by_user: deleted_by_user)
      end

      # Sweep all platforms in an account in one call (used by the
      # daily reaper job). Yields per-platform Result via summary.
      def sweep_account!(account:, grace_days: DEFAULT_GRACE_DAYS)
        per_platform = {}
        account.system_node_platforms.find_each do |platform|
          per_platform[platform.id] = sweep!(platform: platform, grace_days: grace_days)
        end
        per_platform
      end
    end

    def sweep!(platform:, grace_days:, deleted_by_user: nil)
      keep = (platform.disk_image_retention_count || 3).to_i
      keep = 1 if keep < 1

      retired_count = retire_excess!(platform, keep, deleted_by_user: deleted_by_user)
      purged_count  = purge_expired!(platform, grace_days, deleted_by_user: deleted_by_user)

      emit_swept_event(platform, retired_count, purged_count) if (retired_count + purged_count).positive?

      Result.new(retired_count: retired_count, purged_count: purged_count, errors: @errors || [])
    end

    private

    # Retires every published publication older than the latest `keep`
    # publications. Skips the publication that's currently active on
    # the platform (disk_image_file_object_id match), so a rollback to
    # an older row doesn't get instantly retired by the next sweep.
    def retire_excess!(platform, keep, deleted_by_user:)
      published = platform.disk_image_publications
                          .published_state
                          .order(published_at: :desc)
                          .to_a
      return 0 if published.length <= keep

      to_retire = published.drop(keep).reject do |pub|
        pub.file_object_id == platform.disk_image_file_object_id
      end
      to_retire.each do |pub|
        pub.retire!(deleted_by_user: deleted_by_user)
      rescue StandardError => e
        record_error("retire failed for #{pub.id}: #{e.message}")
      end
      to_retire.length
    end

    def purge_expired!(platform, grace_days, deleted_by_user:)
      to_purge = platform.disk_image_publications.purgeable(grace_days: grace_days).to_a
      to_purge.each do |pub|
        pub.purge!(deleted_by_user: deleted_by_user)
      rescue StandardError => e
        record_error("purge failed for #{pub.id}: #{e.message}")
      end
      to_purge.length
    end

    def record_error(message)
      Rails.logger.warn "[DiskImageRetentionService] #{message}"
      (@errors ||= []) << message
    end

    def emit_swept_event(platform, retired_count, purged_count)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account:  platform.account,
        kind:     "system.disk_image_retention_swept",
        severity: :low,
        source:   "retention_sweep",
        payload: {
          platform_id:     platform.id,
          platform_name:   platform.name,
          retained_count:  platform.disk_image_retention_count,
          retired_count:   retired_count,
          purged_count:    purged_count
        }
      )
    rescue StandardError => e
      Rails.logger.warn "[DiskImageRetentionService] swept event emit failed: #{e.class}: #{e.message}"
    end
  end
end
