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
# IMP-ff6d46f2c3e1: this job's own #execute summary now mirrors every
# counter the controller aggregates (previously only
# account/region/synced/updated), so an operator tailing this Sidekiq job's
# log sees the same picture the controller computed instead of a partial
# one. That is NOT the fix for gap (1) of IMP-8225624f46b1 (a terminated row
# whose guest the provider still lists) — a log line is not a sensor. The
# actual remediation path is entirely server-side and does not go through
# this job at all: System::CloudSyncService writes a System::FleetEvent
# (TERMINATED_GUEST_CHECK_EVENT_KIND) synchronously inside the SAME request
# this job's HTTP call triggers, and System::Fleet::Sensors::
# TerminatedGuestPresentSensor reads that event trail on its own 60s tick,
# independent of whether this job ever runs again or what it logs. These
# fields are added here purely so the omission this finding named is not
# left standing in the one place a human might still read it.
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

    results = payload["results"]
    summary = {
      account_count: (results || []).size,
      region_count: total_region_count(results),
      synced_count: total_synced_count(results),
      updated_count: total_updated_count(results),
      # IMP-ff6d46f2c3e1: previously dropped on the floor here. Always
      # present, zero included explicitly — a clean tick must log the same
      # shape a tick that found something does, or "0" and "never summed"
      # become indistinguishable to whoever reads this line.
      held_count: total_count(results, "held_count"),
      guest_lost_count: total_count(results, "guest_lost_count"),
      ambiguous_count: total_count(results, "ambiguous_count"),
      terminated_guest_present_count: total_terminated_guest_present_count(results)
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

  def total_count(results, key)
    Array(results).sum { |r| r[key].to_i }
  end

  def total_terminated_guest_present_count(results)
    Array(results).sum { |r| Array(r["terminated_guest_present"]).size }
  end
end
