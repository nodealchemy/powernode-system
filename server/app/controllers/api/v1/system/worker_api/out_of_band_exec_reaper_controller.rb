# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-callable endpoint for the */5-minute sweep over
        # Ai::DeferredOperation rows stuck `executing` under
        # system.instance.out_of_band_exec past timeout_seconds+margin.
        # OutOfBandExecReaperJob POSTs here from the maintenance
        # queue. Mirrors IdentityReaperController exactly.
        #
        # POST /api/v1/system/worker_api/out_of_band_exec/reap
        #   Auth: X-Worker-Token (worker JWT / mTLS)
        #   Response: { data: { ok, failed_count, ran_at } }
        class OutOfBandExecReaperController < BaseController
          # Security review findings S7 / R2-4 / C2-1. The first fix here used
          # system.instances.control — WRONG in production: that resource's
          # `control` action is granted `admin: :all` only (engine.rb), no
          # system_worker grant at all, so the real reaper would 403 on every
          # sweep. Landed on system.node_instances.manage instead (team-lead
          # accepted this over a new dedicated permission): already granted
          # `system_worker: :all` in engine.rb, and the SAME permission five
          # other worker_api node-instance-mutating actions already require
          # (worker_api/node_instances_controller.rb) — a real, already-held
          # permission, no new grant.
          def create
            authorize_worker_permission!("system.node_instances.manage")

            result = ::System::OutOfBandExecReaperService.run!

            render_success(
              ok:           result.ok?,
              failed_count: result.failed_count,
              ran_at:       result.ran_at&.iso8601
            )
          rescue BaseController::WorkerPermissionDenied
            # MUST be its own clause, ahead of the blanket StandardError
            # rescue below — a bare `rescue StandardError` here would swallow
            # this and render a 500 before the class-level `rescue_from
            # WorkerPermissionDenied` (BaseController) ever saw it, defeating
            # the RAISE contract #authorize_worker_permission! documents
            # itself around (BaseController's own header: 62 sites, the
            # 2026-08-24 measured bypass). Re-raise so the base class's own
            # handler renders the intended 403.
            raise
          rescue StandardError => e
            Rails.logger.error("[OutOfBandExecReaperController] #{e.class}: #{e.message}")
            render_error("Out-of-band exec reaper failed: #{e.message}", status: :internal_server_error)
          end
        end
      end
    end
  end
end
