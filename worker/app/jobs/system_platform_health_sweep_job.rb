# frozen_string_literal: true

# Periodic tick for the System extension's scheduled platform-health duty
# (campaign 01a07025 increment 3).
#
# Runs every 5 minutes (configured via sidekiq-cron) — deliberately more often
# than the check needs, because the ACTUAL cadence is decided server-side by
# System::Platform::ScheduledHealthCheckService reading the
# `system.platform_health_check_interval_minutes` SiteSetting (default 15
# minutes when unset), never by this job's own tick frequency. Ticking often
# and self-gating server-side means an operator can retune the cadence
# without a deploy — the same shape already used by
# system_fleet_reconcile (60s tick, server-side heartbeat cutoffs) and
# gitops_sync (5min tick, per-repo `last_synced_at` due-check).
#
# Hits /api/v1/system/worker_api/platform/health_sweep, which persists a
# System::PlatformHealthSnapshot AND writes an Ai::AgentExecution row naming
# the account's own System Concierge clone — the two things that were
# missing before this increment (the probe existed and worked; nothing ran
# it on a schedule, and nothing credited an agent for running it).
#
# The worker side is intentionally a thin HTTP shim — all logic lives
# server-side where it can read the System/Ai models directly. This
# preserves the worker-server boundary (worker is API-only).
class SystemPlatformHealthSweepJob < BaseJob
  sidekiq_options queue: "system", retry: 1

  # Self-rate-limiting via server-side due-checks per account, but a Redis
  # lock still caps concurrent ticks so two workers can't double-fire when
  # the cron pool is busy — same pattern as SystemFleetReconcileJob.
  CONCURRENCY_LOCK = "system:platform_health:sweep:lock"
  LOCK_TTL_SEC = 240

  def execute(*_args)
    return { skipped: true, reason: "already locked" } unless acquire_lock

    log_info("[PlatformHealthSweep] Starting sweep tick")
    response = api_client.post("/api/v1/system/worker_api/platform/health_sweep", {})
    payload = response.dig("data") || {}

    summary = {
      account_count: payload["account_count"] || 0,
      ran_count: ran_count(payload["results"]),
      skipped_count: skipped_count(payload["results"])
    }
    log_info("[PlatformHealthSweep] Tick complete", **summary)
    summary
  rescue BackendApiClient::ApiError => e
    log_error("[PlatformHealthSweep] API error", e)
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

  def ran_count(results)
    Array(results).count { |r| r["ran"] }
  end

  def skipped_count(results)
    Array(results).count { |r| !r["ran"] }
  end
end
