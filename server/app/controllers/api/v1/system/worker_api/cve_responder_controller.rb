# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-side entry point for the CVE Responder agent's reconcile
        # tick. Mirrors FleetController#reconcile shape verbatim. The
        # standalone worker (powernode-worker@default) hits this endpoint
        # every 60s via SystemCveResponderReconcileJob.
        #
        # Always returns 200 with a per-account summary so a mid-tick
        # failure on one account doesn't take down the whole loop.
        #
        # Permission: shares `system.fleet.reconcile` with the fleet tick
        # and CVE feed ingest — workers seeded for fleet reconcile already
        # have it. Separating into a dedicated `system.cve.reconcile`
        # permission is a future refinement when role granularity matters.
        class CveResponderController < BaseController
          def reconcile
            authorize_worker_permission!("system.fleet.reconcile")
            return if performed?

            accounts = scope_accounts
            results = accounts.map do |account|
              tick_result = ::System::CveOps::CveResponderService.tick!(account: account)
              { account_id: account.id }.merge(tick_result)
            rescue StandardError => e
              Rails.logger.error("[CveResponder] account=#{account.id} failed: #{e.class}: #{e.message}")
              { account_id: account.id, ok: false, error: e.message }
            end

            render_success({
              tick_count: results.size,
              results: results
            })
          end

          private

          def scope_accounts
            if current_worker.account?
              [ current_worker.account ]
            else
              account_ids = ::System::NodeInstance
                .joins(:node)
                .distinct
                .pluck("system_nodes.account_id")
              Account.where(id: account_ids)
            end
          end
        end
      end
    end
  end
end
