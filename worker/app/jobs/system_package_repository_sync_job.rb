# frozen_string_literal: true

# Periodic apt/rpm package repository synchronization tick.
#
# Runs daily at 5:00 AM UTC. Hits the server's worker_api endpoint which:
#   1. Iterates every enabled PackageRepository (account-scoped + shared)
#   2. Per repo: invokes PackageRepositorySyncService.call
#   3. The service fetches the upstream index, parses, batch-upserts Package
#      rows, soft-deletes obsoleted entries, and updates repo sync status.
#
# Per-repo failures are isolated server-side; one bad repo (auth failure,
# network timeout, malformed index) does not poison the tick.
class SystemPackageRepositorySyncJob < BaseJob
  sidekiq_options queue: "system", retry: 1

  CONCURRENCY_LOCK = "system:pkgrepo:sync:lock"
  LOCK_TTL_SEC = 1800 # 30 minutes — bounded by Ubuntu archive fetch latency on slow links

  def execute(*_args)
    return { skipped: true, reason: "already locked" } unless acquire_lock

    log_info("[PackageRepoSync] Starting daily sync tick")
    response = api_client.post("/api/v1/system/worker_api/package_repositories/sync", {})
    payload = response.dig("data") || {}

    summary = {
      tick_count:      payload["tick_count"] || 0,
      upserted_total:  total_upserted(payload["results"]),
      obsoleted_total: total_obsoleted(payload["results"]),
      failed_count:    failed_count(payload["results"])
    }
    log_info("[PackageRepoSync] Tick complete", **summary)
    summary
  rescue BackendApiClient::ApiError => e
    log_error("[PackageRepoSync] API error", e)
    { ok: false, error: e.message }
  ensure
    release_lock
  end

  private

  def acquire_lock
    Sidekiq.redis { |c| c.set(CONCURRENCY_LOCK, Time.current.to_f, nx: true, ex: LOCK_TTL_SEC) }
  end

  def release_lock
    Sidekiq.redis { |c| c.del(CONCURRENCY_LOCK) }
  rescue StandardError
    nil
  end

  def total_upserted(results)
    Array(results).sum { |r| r["upserted"].to_i }
  end

  def total_obsoleted(results)
    Array(results).sum { |r| r["obsoleted"].to_i }
  end

  def failed_count(results)
    Array(results).count { |r| !r["ok"] }
  end
end
