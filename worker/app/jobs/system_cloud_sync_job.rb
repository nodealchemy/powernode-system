# frozen_string_literal: true

# Periodic cloud-state reconciliation for the System extension.
#
# Runs hourly at :17 (configured via sidekiq-cron). Hits the server's
# /api/v1/system/worker_api/cloud_sync/reconcile endpoint, which:
#   1. Iterates every account that has a System::ProviderConnection
#   2. For each account, syncs every active System::ProviderRegion via
#      System::CloudSyncService.sync_region_instances
#   3. Updates last_synced_at + drift status on each NodeInstance
#
# Worker side is intentionally a thin HTTP shim — the heavy lifting is
# server-side where it can read System models directly.
#
# Reference: Golden Eclipse plan + comprehensive stabilization sweep P2.1.
class SystemCloudSyncJob < BaseJob
  sidekiq_options queue: "system", retry: 1

  # Single-flight guarantee: a slow tick (large fleet, slow cloud APIs)
  # must NOT trigger a second concurrent run. Cron at :17 hourly gives
  # 60 minutes of headroom; the lock TTL is conservative.
  CONCURRENCY_LOCK = "system:cloud_sync:lock"
  LOCK_TTL_SEC = 1800 # 30 minutes — bounded by cloud-API timeouts

  def execute(*_args)
    return { skipped: true, reason: "already locked" } unless acquire_lock

    log_info("[CloudSync] Starting cloud-state reconcile tick")
    response = api_client.post("/api/v1/system/worker_api/cloud_sync/reconcile", {})
    payload = response.dig("data") || {}

    summary = {
      account_count: (payload["results"] || []).size,
      region_count: total_region_count(payload["results"]),
      synced_count: total_synced_count(payload["results"]),
      updated_count: total_updated_count(payload["results"])
    }
    log_info("[CloudSync] Tick complete", **summary)
    summary
  rescue BackendApiClient::ApiError => e
    log_error("[CloudSync] API error", e)
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

  def total_region_count(results)
    Array(results).sum { |r| r["region_count"].to_i }
  end

  def total_synced_count(results)
    Array(results).sum { |r| r["synced_count"].to_i }
  end

  def total_updated_count(results)
    Array(results).sum { |r| r["updated_count"].to_i }
  end
end
