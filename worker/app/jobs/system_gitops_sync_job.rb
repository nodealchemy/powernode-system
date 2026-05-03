# frozen_string_literal: true

# Periodic GitOps reconciliation tick.
#
# Runs every 5 minutes. Hits the server's worker_api endpoint which:
#   1. Iterates every account that has at least one enabled GitopsRepository
#   2. For each account, iterates due-for-sync repositories
#   3. Per repo: clones/pulls → parses fleet.yaml → diffs vs live →
#      opens Ai::AgentProposal rows
#
# Reference: comprehensive stabilization sweep P5; Golden Eclipse M-D2-3.
class SystemGitopsSyncJob < BaseJob
  sidekiq_options queue: "system", retry: 1

  CONCURRENCY_LOCK = "system:gitops:sync:lock"
  LOCK_TTL_SEC = 600 # 10 minutes — bounded by clone latency on slow links

  def execute(*_args)
    return { skipped: true, reason: "already locked" } unless acquire_lock

    log_info("[GitopsSync] Starting reconcile tick")
    response = api_client.post("/api/v1/system/worker_api/gitops/reconcile", {})
    payload = response.dig("data") || {}

    summary = {
      tick_count: payload["tick_count"] || 0,
      diff_count: total_diff_count(payload["results"]),
      proposal_count: total_proposal_count(payload["results"])
    }
    log_info("[GitopsSync] Tick complete", **summary)
    summary
  rescue BackendApiClient::ApiError => e
    log_error("[GitopsSync] API error", e)
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

  def total_diff_count(results)
    Array(results).sum { |r| r["diff_count"].to_i }
  end

  def total_proposal_count(results)
    Array(results).sum { |r| Array(r["proposal_ids"]).size }
  end
end
