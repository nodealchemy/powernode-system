# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-callable endpoint that triggers the ACME renewal sweep.
        # The Sidekiq job `AcmeCertificateRenewalJob` POSTs here every
        # 6 hours; the controller invokes Acme::RenewalSweepService.run!
        # which finds expiring certs + retries failed certs past the
        # cooldown.
        #
        # POST /api/v1/system/worker_api/acme/renewal_sweep
        #   Auth: X-Worker-Token (worker JWT)
        #   Response: { data: { renewed_count, failed_count, skipped_count,
        #                       findings, ran_at } }
        #
        # Plan reference: Decentralized Federation §J + P2.5.5.
        class AcmeRenewalSweepController < BaseController
          def create
            result = ::Acme::RenewalSweepService.run!

            render_success(
              ok: result.ok?,
              renewed_count: result.renewed_count,
              failed_count: result.failed_count,
              skipped_count: result.skipped_count,
              findings: result.findings,
              ran_at: result.ran_at&.iso8601
            )
          rescue StandardError => e
            Rails.logger.error("[AcmeRenewalSweepController] #{e.class}: #{e.message}")
            render_error("Renewal sweep failed: #{e.message}", status: :internal_server_error)
          end
        end
      end
    end
  end
end
