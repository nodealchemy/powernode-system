# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-callable endpoint that triggers the symmetric-peer trust-bundle
        # refresh. The Sidekiq job `FederationTrustBundleRefreshJob` POSTs here
        # hourly; the controller invokes
        # ::Federation::TrustBundleRefreshService.run! which re-fetches each
        # symmetric peer's CA bundle, updates trusted_ca_pem on rotation, and
        # rewrites the Traefik client-auth bundle.
        #
        # POST /api/v1/system/worker_api/federation/trust_bundle_refresh
        #   Auth: worker mTLS (BaseController#authenticate_worker!)
        #   Response: { data: { checked, updated, failures } }
        #
        # Federation mTLS Phase 2 (symmetric).
        class FederationTrustBundleController < BaseController
          def create
            result = ::Federation::TrustBundleRefreshService.run!

            render_success(
              checked:  result.checked,
              updated:  result.updated,
              failures: result.failures
            )
          rescue StandardError => e
            Rails.logger.error(
              "[FederationTrustBundleController] refresh failed: #{e.class}: #{e.message}"
            )
            render_error("federation_trust_bundle_refresh_failed: #{e.message}", :internal_server_error)
          end
        end
      end
    end
  end
end
