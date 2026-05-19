# frozen_string_literal: true

# Daily compliance-snapshot archival job. Mirrors SystemFleetEventRetentionJob's
# shape: holds a Redis lock, POSTs the worker_api endpoint, returns aggregate.
#
# Server-side does the work (DailySnapshotArchivalService): per account,
# generates a snapshot via ComplianceSnapshotService and emits a FleetEvent
# with kind="system.compliance.snapshot". The existing FleetEvent retention
# sweep handles pruning — no separate compliance-snapshot table needed.
#
# Cron: daily at 4:45 AM UTC (after fleet event retention sweep so the prior
# day's snapshot is already in the durable window).
#
# Reference: audit plan P2.8d.
class SystemComplianceSnapshotJob < BaseJob
  sidekiq_options queue: "maintenance", retry: 1

  CONCURRENCY_LOCK = "system:compliance_snapshot:lock"
  LOCK_TTL_SEC = 1800

  def execute(*_args)
    return { skipped: true, reason: "already locked" } unless acquire_lock

    log_info("[ComplianceSnapshot] Starting daily archival")
    response = api_client.post("/api/v1/system/worker_api/compliance/archive", {})
    payload = response.dig("data") || {}
    summary = {
      snapshots_emitted: payload["snapshots_emitted"],
      accounts_failed:   payload["accounts_failed"],
      errors:            Array(payload["errors"])
    }
    log_info("[ComplianceSnapshot] Archival complete", **summary.except(:errors))
    summary[:errors].each { |e| log_warn("[ComplianceSnapshot] per-account failure", **e) }
    summary
  rescue BackendApiClient::ApiError => e
    log_error("[ComplianceSnapshot] API error", e)
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
