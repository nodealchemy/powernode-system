# frozen_string_literal: true

# Embeds packages for a PackageRepository.
#
# The server does the heavy lifting — this job is a thin orchestration loop:
# call /worker_api/packages/process_embedding_batch until `remaining: 0`.
# Each batch the server leases a chunk, generates embeddings (via
# Ai::Memory::EmbeddingService which proxies to the worker over HTTP for the
# actual provider call), and writes them back.
#
# Invoked by:
#   * PackageRepositorySyncService after a sync that upserted ≥1 row
#     (fresh metadata gets fresh embeddings)
#   * The `rake system:packages:backfill_embeddings` rake task (one-time
#     backfill against pre-existing catalogs)
#
# Concurrency: per-repo Redis lock (3h TTL — enough headroom for big repos
# while still allowing manual re-runs after a long gap). A second enqueue
# for the same repo while a run is in flight returns `skipped: true` and
# does not retry.
class SystemPackageEmbeddingJob < BaseJob
  sidekiq_options queue: "system", retry: 2

  LOCK_TTL_SEC      = 3 * 3600
  MAX_BATCHES       = 2000              # safety stop (200 max batch × 2000 = 400k rows)
  DEFAULT_BATCH     = 50

  # job args: [repository_id, options = {force: false, batch_size: 50}]
  def execute(repository_id, options = {})
    options = (options || {}).transform_keys(&:to_s)
    batch_size = (options["batch_size"] || DEFAULT_BATCH).to_i
    force      = options["force"] == true || options["force"] == "true"

    lock_key = "system:pkg:embed:#{repository_id}"
    return { skipped: true, reason: "already locked", repository_id: repository_id } unless acquire_lock(lock_key)

    log_info("[PackageEmbedding] start", repository_id: repository_id, batch_size: batch_size, force: force)

    total_processed = 0
    total_errors    = 0
    batches         = 0

    MAX_BATCHES.times do
      batches += 1
      response = api_client.post(
        "/api/v1/system/worker_api/packages/process_embedding_batch",
        {
          repository_id: repository_id,
          batch_size:    batch_size,
          force:         force
        }
      )
      data = response["data"] || {}

      processed       = data["processed"].to_i
      remaining       = data["remaining"].to_i
      errors          = Array(data["errors"])
      total_processed += processed
      total_errors    += errors.size

      log_info("[PackageEmbedding] batch",
               repository_id: repository_id,
               batch: batches,
               processed: processed,
               remaining: remaining,
               errors: errors.size)

      break if processed.zero? && remaining.zero?
      # Server signaled there's nothing left to lease but a previous run is
      # mid-flight — back off rather than spinning. Sidekiq retry will pick
      # it up later if needed.
      break if processed.zero? && remaining.positive?
    end

    log_info("[PackageEmbedding] complete",
             repository_id: repository_id,
             total_processed: total_processed,
             total_errors: total_errors,
             batches: batches)

    {
      ok:              true,
      repository_id:   repository_id,
      total_processed: total_processed,
      total_errors:    total_errors,
      batches:         batches
    }
  rescue BackendApiClient::ApiError => e
    log_error("[PackageEmbedding] API error", e)
    raise
  ensure
    release_lock(lock_key) if lock_key
  end

  private

  def acquire_lock(key)
    Sidekiq.redis { |c| c.set(key, Time.current.to_f, nx: true, ex: LOCK_TTL_SEC) }
  end

  def release_lock(key)
    Sidekiq.redis { |c| c.del(key) }
  rescue StandardError
    nil
  end
end
