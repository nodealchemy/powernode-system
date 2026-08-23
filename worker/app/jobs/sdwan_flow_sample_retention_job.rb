# frozen_string_literal: true

# IMP-b24afe85a309 — nightly retention sweep for system_sdwan_flow_samples,
# the IPFIX flow-samples firehose. Runs daily at 3:15 AM UTC, deliberately
# offset from SystemFleetEventRetentionJob (4:30) so the two maintenance
# sweeps do not contend for the same autovacuum window.
#
# Retention is NOT configured here: the window, batch size and per-run ceiling
# are all DB-driven (Account#settings, then SiteSetting), resolved server-side
# by Sdwan::FlowSampleRetentionService. This job only decides WHEN.
#
# The deletion runs via the platform server rather than in the worker so
# per-account scoping resolves against the same settings the consuming sensor
# reads — and because the worker talks to the server over the HTTP API only.
#
# `capped: true` in the summary means the run hit its per-run ceiling with rows
# still eligible: the backlog is draining over multiple nights, which is the
# intended behaviour on a table that has never been swept, not an error.
class SdwanFlowSampleRetentionJob < BaseJob
  sidekiq_options queue: "maintenance", retry: 1

  CONCURRENCY_LOCK = "sdwan:flow_sample_retention:lock"
  # Longer than the fleet sweep's TTL: the first runs on an unswept table work
  # through a large backlog in batches, and a lock that expires mid-sweep would
  # let a second run start deleting alongside the first.
  LOCK_TTL_SEC = 3600

  def execute(*_args)
    return { skipped: true, reason: "already locked" } unless acquire_lock

    log_info("[FlowSampleRetention] Starting nightly sweep")
    response = api_client.post("/api/v1/system/worker_api/sdwan/flow_sample_retention_sweep", {})
    payload = response.dig("data") || {}
    summary = {
      accounts: payload["accounts"],
      deleted_total: payload["deleted_total"],
      batches: payload["batches"],
      capped: payload["capped"],
      floored: payload["floored"]
    }
    log_info("[FlowSampleRetention] Sweep complete", **summary)
    summary
  rescue BackendApiClient::ApiError => e
    log_error("[FlowSampleRetention] API error", e)
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
