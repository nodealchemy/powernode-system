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

            repos = scope_repositories
            results = repos.map do |repo|
              sync_one(repo)
            rescue StandardError => e
              Rails.logger.error("[PackageRepositorySync] repository=#{repo.id} failed: #{e.class}: #{e.message}")
              { repository_id: repo.id, ok: false, error: e.message }
            end

            render_success(
              tick_count: results.size,
              results:    results
            )
          end

          private

          def sync_one(repo)
            result = ::System::PackageRepositorySyncService.call(repository: repo)
            {
              repository_id: repo.id,
              ok:            result.success?,
              upserted:      result.upserted,
              obsoleted:     result.obsoleted,
              package_count: result.package_count,
              error:         result.error
            }
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
