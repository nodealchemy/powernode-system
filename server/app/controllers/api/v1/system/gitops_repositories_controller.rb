# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator CRUD + manual trigger for GitOps repositories.
      # Permission gates:
      #   - system.gitops.read   — index, show, sync_runs
      #   - system.gitops.write  — create, update, destroy
      #   - system.gitops.sync   — sync_now
      #
      # Reference: comprehensive stabilization sweep P5.
      class GitopsRepositoriesController < BaseController
        before_action :set_account
        before_action :set_repository, only: %i[show update destroy sync_now sync_runs]

        def index
          require_permission("system.gitops.read")
          repos = @account.system_gitops_repositories.order(:name)
          repos = repos.enabled if params[:enabled] == "true"
          repos = paginate(repos)
          render_success(gitops_repositories: repos.map { |r| serialize_repo(r) }, meta: pagination_meta)
        end

        def show
          require_permission("system.gitops.read")
          render_success(
            gitops_repository: serialize_repo(@repository),
            recent_runs: @repository.sync_runs.recent.limit(10).map { |r| serialize_run(r) }
          )
        end

        def create
          require_permission("system.gitops.write")
          repo = @account.system_gitops_repositories.build(repository_params)
          if repo.save
            render_success(gitops_repository: serialize_repo(repo), status: :created)
          else
            render_validation_error(repo)
          end
        end

        def update
          require_permission("system.gitops.write")
          if @repository.update(repository_params)
            render_success(gitops_repository: serialize_repo(@repository))
          else
            render_validation_error(@repository)
          end
        end

        def destroy
          require_permission("system.gitops.write")
          if @repository.destroy
            render_success(message: "Repository deleted")
          else
            render_error("Failed to delete repository", status: :unprocessable_entity)
          end
        end

        # POST /api/v1/system/gitops_repositories/:id/sync_now
        # Fires an off-schedule reconciliation tick. Useful for "I just pushed
        # a fix; reconcile now" rather than waiting for the next 5-min cron.
        def sync_now
          require_permission("system.gitops.sync")

          run = @repository.schedule_sync!
          # Synchronous reconciliation — small repos finish in <10s. Larger
          # repos should still be tolerable; if not, we'd dispatch to the
          # worker. For now, inline keeps the API simple.
          result = ::System::Gitops::Reconciler.reconcile!(repository: @repository, sync_run: run)

          render_success(
            sync_run: serialize_run(run.reload),
            ok: result.ok?,
            diff_count: result.diff_count,
            proposal_ids: result.proposal_ids
          )
        end

        # GET /api/v1/system/gitops_repositories/:id/sync_runs
        def sync_runs
          require_permission("system.gitops.read")
          runs = @repository.sync_runs.recent.limit(50)
          render_success(sync_runs: runs.map { |r| serialize_run(r) })
        end

        private

        def set_repository
          @repository = @account.system_gitops_repositories.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("GitOps Repository")
        end

        def repository_params
          params.require(:gitops_repository).permit(
            :name, :repo_url, :branch, :vault_credential_path, :path_prefix,
            :enabled, :auto_apply, metadata: {}
          )
        end

        def serialize_repo(repo)
          {
            id: repo.id,
            name: repo.name,
            repo_url: repo.repo_url,
            branch: repo.branch,
            path_prefix: repo.path_prefix,
            enabled: repo.enabled,
            auto_apply: repo.auto_apply,
            last_synced_at: repo.last_synced_at,
            last_synced_revision: repo.last_synced_revision,
            last_diff_count: repo.last_diff_count,
            last_status: repo.last_status,
            last_error: repo.last_error,
            metadata: repo.metadata,
            created_at: repo.created_at,
            updated_at: repo.updated_at
          }
        end

        def serialize_run(run)
          {
            id: run.id,
            started_at: run.started_at,
            completed_at: run.completed_at,
            duration_seconds: run.duration_seconds,
            diff_count: run.diff_count,
            proposal_ids: run.proposal_ids,
            status: run.status,
            synced_revision: run.synced_revision,
            error_message: run.error_message,
            diff_summary: run.diff_summary
          }
        end
      end
    end
  end
end
