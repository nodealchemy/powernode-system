# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-callable endpoint that triggers the subscription
        # monitor sweep. The Sidekiq job
        # `FederationSubscriptionMonitorJob` POSTs here every hour;
        # the controller invokes
        # Federation::SubscriptionMonitorService.run! which suspends
        # subscriptions with expired grants, retries failed certs past
        # the cooldown, and auto-cancels stale-suspended subscriptions.
        #
        # POST /api/v1/system/worker_api/federation/subscription_monitor
        #   Auth: X-Worker-Token (worker JWT)
        #   Response: { data: { ok, suspended_count, cert_retried_count,
        #                       auto_cancelled_count, findings, ran_at } }
        #
        # Plan reference: Decentralized Federation §L + P4.6.6.
        class SubscriptionMonitorController < BaseController
          def create
            result = ::Federation::SubscriptionMonitorService.run!

            render_success(
              ok: result.ok?,
              suspended_count: result.suspended_count,
              cert_retried_count: result.cert_retried_count,
              auto_cancelled_count: result.auto_cancelled_count,
              findings: result.findings,
              ran_at: result.ran_at&.iso8601
            )
          rescue StandardError => e
            Rails.logger.error("[SubscriptionMonitorController] #{e.class}: #{e.message}")
            render_error("Subscription monitor sweep failed: #{e.message}",
                         status: :internal_server_error)
          end
        end
      end
    end
  end
end
