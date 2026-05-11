# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-side entry point for GitOps reconciliation.
        # Iterates GitopsRepository rows due for sync; per-repo failures are
        # rescued so one bad repo doesn't break the tick.
        #
        # Reference: comprehensive stabilization sweep P5.
        class GitopsController < BaseController
          def reconcile
            authorize_worker_permission!("system.gitops.reconcile")
            return if performed?

            repos = scope_repositories
            results = repos.map do |repo|
              reconcile_one(repo)
            rescue StandardError => e
              Rails.logger.error("[GitopsSync] repository=#{repo.id} failed: #{e.class}: #{e.message}")
              { repository_id: repo.id, ok: false, error: e.message }
            end

            render_success(
              tick_count: results.size,
              results: results
            )
          end

          private

          def reconcile_one(repo)
            result = ::System::Gitops::Reconciler.reconcile!(repository: repo)
            {
              repository_id: repo.id,
              ok: result.success?,
              diff_count: result.diff_count,
              proposal_ids: result.proposal_ids,
              synced_revision: result.synced_revision,
              error: result.error
            }
          end

          def scope_repositories
            repos = ::System::GitopsRepository.due_for_sync(staleness: 5.minutes)
            return repos if current_worker.account?

            repos
          end
        end
      end
    end
  end
end
