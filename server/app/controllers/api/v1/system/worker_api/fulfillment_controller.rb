# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Campaign 019f6084 inc-O — worker-callable FulfillmentRequest sweep.
        #
        # SystemFulfillmentRequestReconcileJob POSTs here on its 60s cron tick
        # (extensions/system/worker/config/sidekiq_system.yml). The controller
        # runs System::FulfillmentRequestSweepService for each account in scope:
        # advance every ADVANCEABLE request one step via
        # System::FulfillmentAdvanceOrchestrator (resuming ones parked at the
        # build barrier / approved out-of-band) and reap task-scoped instances
        # whose lease has elapsed. Sweep logic lives server-side (the worker is
        # HTTP-only) — mirrors CiRunnerLeasesController#advance, the sweep
        # service's own documented analog.
        #
        # POST /api/v1/system/worker_api/fulfillment/sweep
        #   Auth: mTLS (@current_worker — handled by BaseController)
        #   Body (optional): { account_id }  # scope the sweep to one account
        #   Response: { data: { accounts_swept, advanced, reached_ready, failed,
        #                       waiting, requests_expired, instances_reaped, errored } }
        class FulfillmentController < BaseController
          def sweep
            summaries = target_accounts.map do |account|
              ::System::FulfillmentRequestSweepService.run!(account: account)
            end

            render_success(aggregate(summaries).merge(accounts_swept: summaries.size))
          rescue StandardError => e
            Rails.logger.error("[FulfillmentController] sweep failed: #{e.class}: #{e.message}")
            render_error("fulfillment_sweep_failed: #{e.message}", :internal_server_error)
          end

          private

          def target_accounts
            return Array(::Account.find_by(id: params[:account_id])) if params[:account_id].present?

            # Sweep accounts with an open FulfillmentRequest OR a live
            # task_scoped instance: an account can reach zero open requests
            # while still carrying a stray task-scoped instance whose owning
            # request was already archived, so scoping on open requests alone
            # would leave it unreachable by the cron (mirrors
            # CiRunnerLeasesController's orphan-runner scoping).
            account_ids = (
              ::System::FulfillmentRequest.open.distinct.pluck(:account_id) +
              ::System::NodeInstance.where(lifecycle_class: "task_scoped")
                                    .where.not(status: "terminated")
                                    .distinct.pluck(:account_id)
            ).compact.uniq
            ::Account.where(id: account_ids)
          end

          def aggregate(summaries)
            %i[advanced reached_ready failed waiting requests_expired instances_reaped errored].index_with do |key|
              summaries.sum { |summary| summary[key].to_i }
            end
          end
        end
      end
    end
  end
end
