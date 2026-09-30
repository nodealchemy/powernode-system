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

        # IMP-1e5db5e6aefb — an SSH remote's host key is recorded at
        # registration: an explicit `ssh_host_key` ("<type> <base64-key>", as
        # ssh-keyscan prints it) when the operator has one, else a keyscan of
        # the remote's host and port. The response carries fingerprints only.
        # A hostile value is refused whole (422) and nothing is registered.
        def create
          require_permission("system.gitops.write")
          repo = @account.system_gitops_repositories.build(repository_params)
          return unless assign_host_key!(repo, explicit: host_key_param, scan: true)

          if repo.save
            render_success(gitops_repository: serialize_repo(repo), status: :created)
          else
            render_validation_error(repo)
          end
        end

        # `ssh_host_key` on update is the operator's recovery from a
        # host_key_mismatch: the sync never replaces a recorded key itself.
        # Sent blank, it clears the record so the next sync pins on first use.
        def update
          require_permission("system.gitops.write")
          @repository.assign_attributes(repository_params)
          if host_key_param_sent?
            return unless assign_host_key!(@repository, explicit: host_key_param, scan: false)
          end

          if @repository.save
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
            render_error("Failed to delete repository", status: :unprocessable_content)
          end
        end

        # POST /api/v1/system/gitops_repositories/:id/sync_now
        # Fires an off-schedule reconciliation tick. Useful for "I just pushed
        # a fix; reconcile now" rather than waiting for the next 5-min cron.
        def sync_now
          require_permission("system.gitops.sync")

          # Refuse on a standby control plane BEFORE a run exists — the same
          # contract the MCP twin system_gitops_sync_repository adopted under
          # IMP-8ce4d88499a0. The reconciler's own fence performs nothing on
          # standby and returns ok?: true, finalizing whatever run it was
          # handed as "success" with a `skipped` note in diff_summary — the
          # exact shape of a fully in-sync repository. This action used to
          # mint that run and tell the operator to read the marker; a prose
          # caveat is not a contract. Asking ControlPlaneRole here is the same
          # authority the reconciler asks, not a second implementation of the
          # rule. active? is false for :standby AND :gate_error, and neither
          # asserts an active peer exists — only that this plane may not act.
          unless ::System::Autonomy::ControlPlaneRole.active?
            return render_error(
              "standby control plane — this plane is not permitted to reconcile repository " \
              "#{@repository.id} (not elected, or the quorum gate itself errored); reconcile not performed",
              status: :conflict, code: "standby_control_plane"
            )
          end

          run = @repository.schedule_sync!
          # Synchronous reconciliation — small repos finish in <10s. Larger
          # repos should still be tolerable; if not, we'd dispatch to the
          # worker. For now, inline keeps the API simple.
          result = ::System::Gitops::Reconciler.reconcile!(repository: @repository, sync_run: run)

          # result.ok? — the Result struct's actual predicate; the success?
          # call here raised NoMethodError on every invocation from 2026-05-10
          # until IMP-95198e6a57d3.
          payload = {
            sync_run: serialize_run(run.reload),
            ok: result.ok?,
            diff_count: result.diff_count,
            proposal_ids: result.proposal_ids,
            diff_summary: result.diff_summary
          }

          # A reconcile that FAILED is a failure, and a failure must not ride
          # the success channel (IMP-8ce4d88499a0, mirrored from the MCP
          # twin). This used to render_success(ok: false, ...): the reason was
          # in the payload while the one field a program branches on said the
          # sync succeeded — and sync PRECEDES apply, so a caller reading a
          # failed sync as success concluded the fleet matched the repository.
          # The same fields, sync_run included, ride under `details` so the
          # run is still reachable through GET sync_runs.
          unless result.ok?
            return render_error(result.error.presence || "reconcile failed",
                                status: :unprocessable_content, details: payload)
          end

          render_success(**payload)
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

        # An INPUT, not a column: validated by RepositoryHostKey and stored as
        # the normalized document, never assigned raw.
        def host_key_param
          params.require(:gitops_repository)[:ssh_host_key]
        end

        def host_key_param_sent?
          params.require(:gitops_repository).key?(:ssh_host_key)
        end

        # Returns false after rendering the refusal. The refusal names the
        # expected shape and never echoes the value.
        def assign_host_key!(repo, explicit:, scan:)
          if explicit.present?
            ::System::Gitops::RepositoryHostKey.assign_for_registration!(repo, explicit: explicit)
          elsif scan
            ::System::Gitops::RepositoryHostKey.assign_for_registration!(repo)
          else
            repo.ssh_host_keys = nil
          end
          true
        rescue ::System::Gitops::RepositoryHostKey::InvalidHostKey => e
          render_error(e.message, status: :unprocessable_content, code: "invalid_ssh_host_key")
          false
        end

        def serialize_repo(repo)
          {
            id: repo.id,
            name: repo.name,
            repo_url: repo.repo_url,
            branch: repo.branch,
            path_prefix: repo.path_prefix,
            # A Vault KV PATH and a set of key NAMES — never credential
            # material. Both were write-only before IMP-0f914db2c7cf: the API
            # accepted vault_credential_path and never echoed it, so an
            # operator could not confirm which path a failing repository was
            # configured with. Pair them with
            # POST /api/v1/admin_settings/vault/test { path:, required_keys: }
            # to see whether that path resolves and carries these keys.
            vault_credential_path: repo.vault_credential_path,
            required_credential_keys: repo.required_credential_keys,
            # The git host's recorded SSH public key, as FINGERPRINTS plus how
            # and when it was recorded — never the key blob. IMP-1e5db5e6aefb.
            ssh_host_key_fingerprints: repo.ssh_host_key_fingerprints,
            ssh_host_key_source: repo.ssh_host_key_source,
            ssh_host_key_recorded_at: repo.ssh_host_key_recorded_at,
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
