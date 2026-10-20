# frozen_string_literal: true

# Best-effort post-enrolment seed cleanup tick (Provisioning D13).
#
# Runs every minute and POSTs /api/v1/system/worker_api/seed_cleanup/sweep, which
# does bounded synchronous provider I/O (a ~15s wall-clock budget, 5 rows per
# tick, each row leased before its provider call). The call is made with
# post_no_retry and a short timeout: a retried request would overlap itself, and
# the server-side lease is the real guard against double processing. A thin HTTP
# shim; all logic is server-side (worker is API-only).
class SystemSeedCleanupJob < BaseJob
  sidekiq_options queue: "system", retry: 0

  ENDPOINT = "/api/v1/system/worker_api/seed_cleanup/sweep"
  REQUEST_TIMEOUT_SEC = 45
  CONCURRENCY_LOCK = "system:seed_cleanup:lock"
  LOCK_TTL_SEC = 60

  def execute(*_args)
    return { skipped: true, reason: "already locked" } unless (locked = acquire_lock)

    response = api_client.post_no_retry(ENDPOINT, {}, timeout: REQUEST_TIMEOUT_SEC)
    swept = response.dig("data", "swept").to_i
    log_info("[SeedCleanup] Sweep complete", swept: swept)
    { swept: swept }
  rescue BackendApiClient::ApiError => e
    log_error("[SeedCleanup] API error", e)
    { ok: false, error: e.message }
  ensure
    release_lock if locked
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
end
