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

  def execute(*args)
    # On-demand single-repo sync (operator "Sync now" button enqueues this
    # job with the repo id). Skips the global daily-tick lock entirely — it
    # targets one repo, is idempotent, and must not be starved by (or starve)
    # the daily all-repos tick.
    repo_id = args.first
    return sync_one_repository(repo_id) if repo_id.present?

    daily_tick
  end

  private

  def daily_tick
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

  # POSTs a single repository id; the server marked it `syncing` before
  # enqueueing, and PackageRepositorySyncService flips it to idle/failed.
  def sync_one_repository(repo_id)
    log_info("[PackageRepoSync] On-demand sync", repository_id: repo_id)
    response = api_client.post(
      "/api/v1/system/worker_api/package_repositories/sync",
      { repository_id: repo_id }
    )
    payload = response.dig("data") || {}
    { on_demand: true, repository_id: repo_id, results: payload["results"] }
  rescue BackendApiClient::ApiError => e
    log_error("[PackageRepoSync] On-demand API error", e)
    { ok: false, error: e.message }
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
