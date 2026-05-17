# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-callable endpoint that triggers the federation heartbeat
        # sweep. The Sidekiq job `FederationHeartbeatJob` POSTs here every
        # 60s; the controller invokes
        # ::System::Federation::HeartbeatSweepService.run! which walks
        # active platform peers with stale last_heartbeat_at and
        # transitions them to `degraded`.
        #
        # POST /api/v1/system/worker_api/federation/heartbeat_sweep
        #   Auth: X-Worker-Token (worker JWT — handled by BaseController)
        #   Response: { data: { swept, degraded_ids, ran_at } }
        #
        # Plan reference: Decentralized Federation §C + P3.5.
        class FederationHeartbeatController < BaseController
          def create
            result = ::System::Federation::HeartbeatSweepService.run!

            render_success(
              swept:        result.swept,
              degraded_ids: result.degraded_ids,
              ran_at:       result.ran_at&.iso8601
            )
          rescue StandardError => e
            Rails.logger.error(
              "[FederationHeartbeatController] sweep failed: #{e.class}: #{e.message}"
            )
            render_error("federation_heartbeat_sweep_failed: #{e.message}", :internal_server_error)
          end
        end
      end
    end
  end
end
