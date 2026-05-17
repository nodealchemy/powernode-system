# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # P9.5 — Worker-callable endpoint for multi-hop migration chain
        # advancement.
        #
        # MigrationChainAdvanceJob POSTs here on its 60s cron tick. The
        # controller invokes ::System::Migrations::ChainSweepService.run!
        # which walks every chain in `planned` / `in_flight` status and
        # advances one hop per chain per tick (cooperative scheduling —
        # this avoids one chain monopolizing the worker by running its
        # whole tail synchronously).
        #
        # POST /api/v1/system/worker_api/migration_chains/advance
        #   Auth: X-Worker-Token (worker JWT — handled by BaseController)
        #   Body (optional): { account_id }
        #     Pass to scope the sweep to a single account (defaults to all).
        #   Response: { data: { swept, advanced, completed, failed, failures } }
        #
        # Plan reference: P9.5 multi-hop migration chains.
        class MigrationChainAdvanceController < BaseController
          def create
            account = scoped_account

            result = ::System::Migrations::ChainSweepService.run!(account: account)

            render_success(
              swept:     result.swept,
              advanced:  result.advanced,
              completed: result.completed,
              failed:    result.failed,
              failures:  result.failures
            )
          rescue StandardError => e
            Rails.logger.error(
              "[MigrationChainAdvanceController] sweep failed: #{e.class}: #{e.message}"
            )
            render_error("migration_chain_advance_failed: #{e.message}",
                         :internal_server_error)
          end

          private

          def scoped_account
            id = params[:account_id].presence
            id && ::Account.find_by(id: id)
          end
        end
      end
    end
  end
end
