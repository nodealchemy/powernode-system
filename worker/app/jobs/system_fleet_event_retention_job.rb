# frozen_string_literal: true

# Nightly retention sweep for System::FleetEvent rows. Runs daily at
# 4:30 AM UTC. Retention is configurable via POWERNODE_FLEET_EVENT_RETENTION_DAYS
# (default 90 days). Critical-severity events get a longer retention bonus
# so an audit trail of high-impact decisions persists past the routine
# noise window.
#
# The deletion runs via the platform server (not directly in the worker)
# so per-account scoping + audit hooks fire correctly.
#
# Reference: Golden Eclipse plan M-D2-1 — fleet event retention sweep.
class SystemFleetEventRetentionJob < BaseJob
  sidekiq_options queue: "maintenance", retry: 1

  CONCURRENCY_LOCK = "system:fleet_event_retention:lock"
  LOCK_TTL_SEC = 1800

  def execute(*_args)
    return { skipped: true, reason: "already locked" } unless acquire_lock

    log_info("[FleetEventRetention] Starting nightly sweep")
    response = api_client.post("/api/v1/system/worker_api/fleet/retention_sweep", {})
    payload = response.dig("data") || {}
    summary = {
      retention_days: payload["retention_days"],
      retention_critical_days: payload["retention_critical_days"],
      deleted_total: payload["deleted_total"],
      deleted_routine: payload["deleted_routine"],
      deleted_critical: payload["deleted_critical"]
    }
    log_info("[FleetEventRetention] Sweep complete", **summary)
    summary
  rescue BackendApiClient::ApiError => e
    log_error("[FleetEventRetention] API error", e)
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
end
