# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Improvement discovery's instance-side endpoints (campaign 01a08c9b
        # D1b), consumed by the agent's ci.lint_discovery handler.
        #
        # Both are gated like ci_build_context, and more tightly. The calling
        # instance must carry the module-forge module, which ships the lint
        # script, AND hold an ACTIVE, UNEXPIRED lint_discovery lease of its own.
        # The lease is found through the mTLS-authenticated instance, never
        # through anything the caller sends, so one instance can never read or
        # write through another's lease.
        #
        # CREDENTIALS. #context returns each leased repository's read credential
        # in its response body and nowhere else. It is never logged, never
        # persisted, never put in the fleet event (ids only) and never in the
        # task. Where a git provider can mint a read-only, repository-scoped
        # token, that is what should be handed out. None of the current
        # provider clients can mint one from a stored token (a Gitea or GitHub
        # personal token cannot be narrowed through its API), so this hands out
        # the repository's own credential.
        class LintDiscoveryController < BaseController
          before_action :require_module_forge!
          before_action :require_active_lease!

          # GET /api/v1/system/node_api/config/ci_lint_context
          def context
            repositories = leased_repositories.filter_map do |repo|
              credential = repo.credential
              next unless credential&.can_be_used?

              {
                id: repo.id,
                clone_url: repo.clone_url_for_devops,
                ref: repo.default_branch.presence || "main",
                username: "x-access-token",
                token: credential.access_token
              }
            end

            emit_event("system.ci_lint_context_issued", "repository_ids" => repositories.map { |r| r[:id] })
            # The runner reports a linter whose output is over core's parse
            # limit as output_truncated instead of cutting it: core never parses
            # a cut report (D1 re-verify M2).
            render_success(repositories: repositories,
                           output_limit_bytes: ::Ai::Codebase::StaticAnalysisService.output_limit_bytes)
          end

          # POST /api/v1/system/node_api/config/ci_lint_result
          #   { run_ref:, repository_id:, base_path:, linters: { ruby: {...}, ... } }
          def result
            unless params[:run_ref].to_s == @lease.id
              return render_error("run_ref does not match this instance's lint_discovery lease", :forbidden)
            end

            repository = leased_repositories.find { |repo| repo.id == params[:repository_id].to_s }
            return render_error("Repository is not part of this lease", :forbidden) if repository.nil?

            if reported_repository_ids.include?(repository.id)
              return render_error("Repository already reported for this lease", :conflict)
            end

            summary = ::Ai::Improvement::DiscoveryRunService.new(account: @lease.account).ingest!(
              repository: repository,
              linters: linter_reports,
              base_path: params[:base_path].to_s,
              run_ref: @lease.id,
              # The one credential this lease handed out for this repository.
              # A result carrying it is filed as nothing (core records
              # credential_in_payload, never the value).
              must_not_contain: [ repository.credential&.access_token ].compact
            )
            mark_reported!(repository.id)

            # `ingest_status`, never `status:`: render_success's `status:` is
            # the HTTP status, and a run status there raises after the filing
            # (critic review of D1b).
            render_success(ingest_status: summary[:status], findings: summary[:findings].to_i,
                           offers_created: summary[:offers_created].to_i)
          end

          private

          def require_module_forge!
            return if current_node.node_modules.exists?(name: ConfigController::MODULE_FORGE_MODULE_NAME)

            render_error("Instance is not provisioned as a module-forge builder", :forbidden)
          end

          # Active AND before its deadline: an expired lease reads nothing and
          # writes nothing, even before the sweep has released it.
          def require_active_lease!
            @lease = ::System::CiRunnerLease
                       .for_node_instance(current_instance)
                       .active
                       .where(purpose: ::System::LintDiscoveryExecutor::PURPOSE)
                       .order(created_at: :desc)
                       .first
            return render_error("Instance has no active lint_discovery lease", :forbidden) if @lease.nil?

            render_error("The lint_discovery lease has expired", :forbidden) if @lease.expired?
          end

          def leased_repositories
            @leased_repositories ||= ::Devops::GitRepository
                                       .where(account_id: @lease.account_id,
                                              id: Array(@lease.metadata["repository_ids"]))
                                       .includes(:credential)
                                       .to_a
          end

          def reported_repository_ids
            Array(@lease.metadata["reported_repository_ids"])
          end

          def mark_reported!(repository_id)
            @lease.with_lock do
              reported = Array(@lease.metadata["reported_repository_ids"])
              @lease.update!(metadata: @lease.metadata.merge("reported_repository_ids" => reported | [ repository_id ]))
            end
          end

          def linter_reports
            raw = params[:linters]
            return {} if raw.blank?

            raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
          end

          def emit_event(kind, payload)
            return unless defined?(::System::Fleet::EventBroadcaster)

            ::System::Fleet::EventBroadcaster.emit!(
              account: current_account,
              kind: kind,
              severity: :low,
              payload: payload.merge("instance_id" => current_instance.id, "lease_id" => @lease.id),
              source: "node_api.lint_discovery"
            )
          end
        end
      end
    end
  end
end
