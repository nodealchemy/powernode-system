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
            if (repo_id = params[:repository_id]).present?
              repo = ::System::PackageRepository.find_by(id: repo_id)
              return render_error("repository not found", status: :not_found) unless repo

              dispatch_background_sync([ repo ])
              return render_success(queued: true, repository_id: repo.id)
            end

            repos = scope_repositories.to_a
            dispatch_background_sync(repos)
            render_success(queued: true, tick_count: repos.size)
          end

          private

          # Runs the sync(s) OUT of the request cycle so the worker's HTTP call
          # returns at once. Detached thread is acceptable: a sync lost to a
          # backend restart leaves the repo `syncing`, and the next tick/click
          # re-syncs it (the advisory lock is released when the process dies).
          # Rails.application.executor.wrap gives the thread its own connection
          # + reloading; each repo is synced sequentially so one thread holds at
          # most one sync connection.
          def dispatch_background_sync(repos)
            return if repos.blank?

            Thread.new do
              ::Rails.application.executor.wrap do
                repos.each do |repo|
                  ::System::PackageRepositorySyncService.call(repository: repo)
                rescue StandardError => e
                  ::Rails.logger.error("[worker_api package sync bg] repository=#{repo.id}: #{e.class}: #{e.message}")
                end
              end
            end
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
