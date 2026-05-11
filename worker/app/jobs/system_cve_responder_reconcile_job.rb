# frozen_string_literal: true

# Periodic reconcile tick for the CVE Responder autonomy service.
#
# Runs every 60 seconds (configured via sidekiq-cron). Hits the server's
# /api/v1/system/worker_api/cve_responder/reconcile endpoint, which:
#   1. Runs the CVE Responder's sensors (CvePublishedSensor,
#      CriticalUpgradeAvailableSensor)
#   2. Routes signals through the shared DecisionEngine (now wired with
#      `system.cve_critical_published` + `system.module_critical_upgrade_ready`
#      bindings)
#   3. For notify_and_proceed (critical severity): dispatches
#      CveRemediationOrchestrationExecutor inline
#   4. For require_approval (other severities): creates Ai::ApprovalRequest
#      with source_type="system_cve_responder"
#   5. Records outcomes via System::CveOps::LearningExtractor
#
# The worker side is a thin HTTP shim — all reconcile logic lives
# server-side. Mirrors SystemFleetReconcileJob shape with a different
# Redis lock so the two ticks can interleave freely.
#
# Reference: CVE Responder agent split (2026-05-10) + completion plan
# we-need-an-agent-transient-zebra.md (2026-05-11).
class SystemCveResponderReconcileJob < BaseJob
  sidekiq_options queue: "system", retry: 1

  # Distinct Redis lock so a busy fleet tick doesn't starve CVE Responder.
  CONCURRENCY_LOCK = "system:cve_responder:reconcile:lock"
  LOCK_TTL_SEC = 90

  def execute(*_args)
    return { skipped: true, reason: "already locked" } unless acquire_lock

    log_info("[CveResponderReconcile] Starting reconcile tick")
    response = api_client.post("/api/v1/system/worker_api/cve_responder/reconcile", {})
    payload = response.dig("data") || {}

    summary = {
      tick_count: payload["tick_count"] || 0,
      decision_count: total_decision_count(payload["results"]),
      signal_count: total_signal_count(payload["results"])
    }
    log_info("[CveResponderReconcile] Tick complete", **summary)
    summary
  rescue BackendApiClient::ApiError => e
    log_error("[CveResponderReconcile] API error", e)
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
