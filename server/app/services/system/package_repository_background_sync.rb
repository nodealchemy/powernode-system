# frozen_string_literal: true

module System
  # Runs one or more package-repository syncs OUT of the puma request cycle, in
  # a standalone process spawned by the worker_api sync endpoint.
  #
  # Why a separate process (not a Thread): a full apt/rpm sync loads + upserts
  # tens of thousands of rows and inflates RSS well past the puma worker
  # recycler's ceiling (config/puma.rb, MAX_WORKER_RSS_MB, 800MB default). When
  # the sync ran as a detached in-worker Thread, the recycler QUIT the worker
  # mid-sync and the thread died with it — stranding the repo in "syncing" with
  # no progress and no error, and the next tick re-ran the same in-worker path
  # and died the same way, so large first-time full syncs never converged.
  #
  # In its own process the sync is immune to the puma worker lifecycle. Recovery
  # is already covered without a bespoke watchdog: the per-repo advisory lock in
  # PackageRepositorySyncService guards against duplicate concurrent runs, the
  # upserts are idempotent, and the daily tick re-drives any repo whose
  # last_synced_at is stale (it filters on last_synced_at, not sync_status), so
  # a process that dies before finalizing is simply re-driven next cycle.
  class PackageRepositoryBackgroundSync
    # Entry point invoked via `rails runner` (see
    # Api::V1::System::WorkerApi::PackageRepositoriesController#dispatch_background_sync).
    # `repository_ids` arrive as ARGV; each repo is synced sequentially so the
    # process holds at most one sync's worth of connections/memory at a time.
    def self.run!(repository_ids:, force: false)
      Array(repository_ids).each do |repo_id|
        repo = ::System::PackageRepository.find_by(id: repo_id)
        next unless repo

        ::System::PackageRepositorySyncService.call(repository: repo, force: force)
      rescue StandardError => e
        ::Rails.logger.error("[PackageRepositoryBackgroundSync] repository=#{repo_id}: #{e.class}: #{e.message}")
      end
    end
  end
end
