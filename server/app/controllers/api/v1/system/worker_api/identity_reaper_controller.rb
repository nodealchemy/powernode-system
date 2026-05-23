# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-callable endpoint for the daily 24h-grace sweep over
        # draining System::ServiceUser / System::ServiceGroup rows.
        # System::IdentityReaperJob POSTs here once a day from the
        # maintenance queue.
        #
        # POST /api/v1/system/worker_api/identity/reap
        #   Auth: X-Worker-Token (worker JWT)
        #   Response: { data: { reaped_users, reaped_groups, ran_at } }
        class IdentityReaperController < BaseController
          def create
            result = ::System::Identity::ReaperService.run!

            render_success(
              ok:            result.ok?,
              reaped_users:  result.reaped_users,
              reaped_groups: result.reaped_groups,
              ran_at:        result.ran_at&.iso8601
            )
          rescue StandardError => e
            Rails.logger.error("[IdentityReaperController] #{e.class}: #{e.message}")
            render_error("Identity reaper failed: #{e.message}", status: :internal_server_error)
          end
        end
      end
    end
  end
end
