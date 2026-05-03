# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-side endpoint that runs the long-pole work for a module
        # publication: manifest re-import, OCI ingest (cosign verify),
        # skill registration, fleet event emission. Called by the worker
        # service's System::ProcessModulePublicationJob, which is itself
        # enqueued by the Gitea webhook receiver.
        #
        # The webhook handles HMAC + module lookup + version snapshot
        # synchronously (~50ms) and dispatches to the worker; the worker
        # job calls back here to do the slow work (~5-10s in steady state,
        # variable under registry load). This keeps the webhook ack fast
        # so Gitea never times out into a retry storm.
        #
        # Reference: webhook async audit follow-up 2026-05-02.
        class ModulePublicationsController < BaseController
          # POST /api/v1/system/worker_api/module_publications/process
          # Body: { node_module_id, tag }
          # Version snapshot is created inside the processor so it reflects
          # the manifest-imported module state, not stale data.
          def process_publication
            authorize_worker_permission!("system.modules.update")

            node_module = ::System::NodeModule.find_by(id: params[:node_module_id])
            return render_not_found("NodeModule") unless node_module

            tag = params[:tag].to_s
            return render_error("tag is required", 400) if tag.blank?

            result = ::System::ModulePublicationProcessor.process!(
              node_module: node_module,
              tag: tag
            )

            if result.ok?
              render_success(
                node_module_version_id: result.node_module_version.id,
                version_number: result.node_module_version.version_number,
                arches: Array(result.artifacts).map { |a| a.respond_to?(:architecture) ? a.architecture : a },
                resolved_dependencies: Array(result.resolved_dependencies)
              )
            else
              # 422 keeps Sidekiq from auto-retrying validation-class failures.
              # Transient failures (network, registry 5xx) come back from the
              # ingest service as :error => "..." and DO retry — Sidekiq's
              # retry middleware treats any non-2xx as retryable.
              render_error(result.error, 422,
                           details: { node_module_version_id: result.node_module_version&.id })
            end
          end
        end
      end
    end
  end
end
