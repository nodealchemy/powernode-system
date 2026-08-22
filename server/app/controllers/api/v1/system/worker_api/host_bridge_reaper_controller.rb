# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-callable endpoint for the daily grace-window sweep over
        # draining Sdwan::HostBridge rows. System::HostBridgeReaperJob POSTs
        # here once a day from the maintenance queue.
        #
        # Shaped on IdentityReaperController, the same worker-invoked reaper
        # pattern this platform already runs for drained ServiceUser /
        # ServiceGroup rows.
        #
        # POST /api/v1/system/worker_api/sdwan/host_bridges/reap
        #   Auth: X-Worker-Token (worker JWT)
        #   Response: { data: { ok, reaped_bridges, ran_at } }
        class HostBridgeReaperController < BaseController
          def create
            result = ::Sdwan::HostBridgeReaper.run!

            render_success(
              ok:             result.ok?,
              reaped_bridges: result.reaped_bridges,
              ran_at:         result.ran_at&.iso8601
            )
          rescue StandardError => e
            Rails.logger.error("[HostBridgeReaperController] #{e.class}: #{e.message}")
            render_error("Host bridge reaper failed: #{e.message}", status: :internal_server_error)
          end
        end
      end
    end
  end
end
