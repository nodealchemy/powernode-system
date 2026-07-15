# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-side entry point for package repository synchronization.
        # Iterates enabled repositories (account-scoped + shared); per-repo
        # failures are rescued so one bad repo doesn't poison the tick.
        class PackageRepositoriesController < BaseController
          def sync
            authorize_worker_permission!("system.package_repositories.sync")
            return if performed?

            # A full apt/rpm sync is a minutes-to-hours operation. Running it
            # INSIDE this request blocked the caller (the worker job) well past
            # its HTTP timeout, so the job failed + retried, and each retry
            # kicked off ANOTHER concurrent sync of the same repo server-side
            # (the request kept running after the client gave up) — a self-
            # amplifying storm. Dispatch the work to a detached background
            # thread and return immediately; the per-repo advisory lock in
            # PackageRepositorySyncService is the real duplicate guard.
            force = ActiveModel::Type::Boolean.new.cast(params[:force]) || false

            if (repo_id = params[:repository_id]).present?
              repo = ::System::PackageRepository.find_by(id: repo_id)
              return render_error("repository not found", status: :not_found) unless repo

              dispatch_background_sync([ repo ], force: force)
              return render_success(queued: true, repository_id: repo.id)
            end

            repos = scope_repositories.to_a
            dispatch_background_sync(repos, force: force)
            render_success(queued: true, tick_count: repos.size)
          end

          private

          # Runs the sync(s) OUT of the request cycle AND out of this puma
          # worker, in a detached child process. A detached in-worker Thread is
          # NOT safe here: a full sync inflates RSS past the puma worker
          # recycler's ceiling (config/puma.rb, MAX_WORKER_RSS_MB), the recycler
          # QUITs the worker, and the thread dies mid-sync — stranding the repo
          # in "syncing" (and the next tick re-ran the same in-worker path and
          # died the same way, so large first syncs never finished). A separate
          # process is immune to the puma worker lifecycle. Recovery needs no
          # bespoke watchdog: the per-repo advisory lock in
          # PackageRepositorySyncService guards duplicates, upserts are
          # idempotent, and the daily tick re-drives any repo with a stale
          # last_synced_at — so a process that dies before finalizing is simply
          # re-driven next cycle.
          def dispatch_background_sync(repos, force: false)
            return if repos.blank?

            ids = repos.map(&:id)
            # `rails runner "<code>" id1 id2 …` exposes the trailing args as ARGV
            # inside <code>; force is a trusted boolean (interpolated literal).
            runner = "System::PackageRepositoryBackgroundSync.run!(repository_ids: ARGV, force: #{force ? 'true' : 'false'})"
            logdev = ::Rails.root.join("log", "package_repository_sync.log").to_s

            pid = ::Process.spawn(
              "bundle", "exec", "rails", "runner", runner, *ids,
              chdir: ::Rails.root.to_s,
              pgroup: true, # own process group — puma signals don't reach it
              %i[out err] => [ logdev, "a" ]
            )
            ::Process.detach(pid) # reap on exit so it doesn't zombie
            ::Rails.logger.info("[worker_api package sync] spawned detached sync pid=#{pid} for #{ids.size} repo(s) force=#{force}")
          rescue StandardError => e
            # If the spawn itself fails the repos stay "syncing" and the next
            # daily tick re-drives them — never fall back to an in-request sync
            # (that was the original HTTP-timeout retry-storm).
            ::Rails.logger.error("[worker_api package sync] failed to spawn detached sync: #{e.class}: #{e.message}")
          end

          # Returns repositories due for sync: enabled + (never synced OR
          # last_synced_at older than the staleness threshold). Pulls both
          # account-scoped and shared repos in one query.
          def scope_repositories
            staleness = (params[:staleness_minutes] || 1440).to_i.minutes # default 24h
            cutoff = Time.current - staleness
            ::System::PackageRepository
              .enabled
              .where("last_synced_at IS NULL OR last_synced_at < ?", cutoff)
          end
        end
      end
    end
  end
end
