# frozen_string_literal: true

# Hourly poll of the NVD JSON feed (or a fixture path in dev/test) to keep
# System::Cve rows fresh. After ingestion, kicks off ExposureCalculator for
# each newly added or updated CVE so System::CveExposure rows reflect the
# fleet's current exposure state.
#
# Reference: Golden Eclipse plan M-D2-2 — system_cve_feed_job.
#
# Server-side endpoint: POST /api/v1/system/worker_api/cve/ingest
class SystemCveFeedJob < BaseJob
  sidekiq_options queue: "system", retry: 2

  CONCURRENCY_LOCK = "system:cve_feed:lock"
  LOCK_TTL_SEC = 600

  def execute(*_args)
    return { skipped: true, reason: "already locked" } unless acquire_lock

    log_info("[CveFeed] Starting hourly ingest")
    response = api_client.post("/api/v1/system/worker_api/cve/ingest", {})
    payload = response.dig("data") || {}
    log_info("[CveFeed] Ingest complete",
             ingested: payload["ingested_count"],
             updated: payload["updated_count"],
             exposures_updated: payload["exposures_updated"])
    { ok: true,
      ingested: payload["ingested_count"].to_i,
      updated: payload["updated_count"].to_i,
      exposures_updated: payload["exposures_updated"].to_i }
  rescue BackendApiClient::ApiError => e
    log_error("[CveFeed] API error", e)
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
