# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Server-side endpoint that the System::ExpireUnclaimedDevicesJob
        # worker job hits on its daily cron tick. Deletes any
        # UnclaimedDevice rows past expires_at across all accounts.
        #
        # Reference: docs/plans/wondrous-yawning-anchor.md §10.
        class UnclaimedDevicesController < BaseController
          # POST /api/v1/system/worker_api/unclaimed_devices/expire
          def expire
            authorize_worker_permission!("system.unclaimed_devices.discard")

            expired = ::System::UnclaimedDevice.expired
            count = expired.count
            expired.in_batches(of: 100).each(&:delete_all)

            # Single FleetEvent summarizing the batch (rather than one per
            # row) keeps the dashboard's event feed signal-to-noise high.
            if count > 0 && defined?(::System::Fleet::EventBroadcaster)
              ::System::Fleet::EventBroadcaster.emit!(
                # Reaper crosses accounts — emit to the platform's first
                # account as a system-wide audit trail.
                account: ::Account.first,
                kind: "system.unclaimed_devices_reaped",
                severity: :low,
                source: "expire_unclaimed_devices_job",
                payload: { reaped_count: count, ran_at: Time.current.iso8601 }
              )
            end

            render_success(reaped_count: count)
          end
        end
      end
    end
  end
end
