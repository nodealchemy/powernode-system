# frozen_string_literal: true

# Periodic reconcile tick for the System extension's FleetAutonomyService.
#
# Runs every 60 seconds (configured via sidekiq-cron). Hits the server's
# /api/v1/system/worker_api/fleet/reconcile endpoint, which:
#   1. Runs all sensors (instance status, module drift, cert expiry,
#      promotion readiness, config drift)
#   2. Routes signals through the DecisionEngine
#   3. Records outcomes via LearningExtractor
#
# The worker side is intentionally a thin HTTP shim — all reconcile logic
# lives server-side where it can read the System models directly. This
# preserves the worker-server boundary (worker is API-only).
#
# Reference: Golden Eclipse plan M7 — system_fleet_reconcile_job.
class SystemFleetReconcileJob < BaseJob
  sidekiq_options queue: "system", retry: 1

  # The reconcile loop is self-rate-limiting (the server checks heartbeat
  # cutoffs). Cap concurrent ticks via Redis lock so two instances can't
  # double-fire when the cron worker pool is busy.
  CONCURRENCY_LOCK = "system:fleet:reconcile:lock"
  LOCK_TTL_SEC = 90

  def execute(*_args)
    return { skipped: true, reason: "already locked" } unless acquire_lock

    log_info("[FleetReconcile] Starting reconcile tick")
    response = api_client.post("/api/v1/system/worker_api/fleet/reconcile", {})
    payload = response.dig("data") || {}

    summary = {
      tick_count: payload["tick_count"] || 0,
      decision_count: total_decision_count(payload["results"]),
      signal_count: total_signal_count(payload["results"])
    }
    log_info("[FleetReconcile] Tick complete", **summary)
    summary
  rescue BackendApiClient::ApiError => e
    log_error("[FleetReconcile] API error", e)
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

  def total_decision_count(results)
    Array(results).sum { |r| r["decision_count"].to_i }
  end

  def total_signal_count(results)
    Array(results).sum { |r| r["signal_count"].to_i }
  end
end
