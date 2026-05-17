# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # P9 — Worker-callable endpoint for auto-policy capability sync.
        #
        # FederationCapabilityAutoSyncJob POSTs here on its cron tick
        # (declared in worker/config/sidekiq.yml under
        # :federation_capability_auto_sync). The controller invokes
        # ::Federation::CapabilityAutoSyncService.run! which walks
        # every capability whose policy is auto_periodic / auto_on_change /
        # on_match_filter and stamps the cursor + dispatches the
        # transport.
        #
        # POST /api/v1/system/worker_api/federation/capability_auto_sync
        #   Auth: X-Worker-Token (worker JWT — handled by BaseController)
        #   Body (optional): { account_id, federation_peer_id }
        #     Pass to scope the sweep to a single account/peer (defaults
        #     to all auto_flow capabilities).
        #   Response: { data: { swept, synced, failed, failures } }
        class FederationCapabilityAutoSyncController < BaseController
          def create
            account = scoped_account
            peer    = scoped_peer

            result = ::Federation::CapabilityAutoSyncService.run!(
              account: account,
              peer:    peer
            )

            render_success(
              swept:    result.swept,
              synced:   result.synced,
              failed:   result.failed,
              failures: result.failures
            )
          rescue StandardError => e
            Rails.logger.error(
              "[FederationCapabilityAutoSyncController] sweep failed: #{e.class}: #{e.message}"
            )
            render_error("federation_capability_auto_sync_failed: #{e.message}",
                         :internal_server_error)
          end

          private

          def scoped_account
            id = params[:account_id].presence
            id && ::Account.find_by(id: id)
          end

          def scoped_peer
            id = params[:federation_peer_id].presence
            id && ::System::FederationPeer.find_by(id: id)
          end
        end
      end
    end
  end
end
