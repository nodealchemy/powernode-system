# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Campaign 019f5885 inc3 — worker-callable CI runner lease reconcile.
        #
        # System::CiRunnerLeaseReconcileJob POSTs here on its 60s cron tick. The
        # controller runs System::CiRunnerLeaseSweepService for each account with
        # active leases: correlate each lease against Gitea run state + publish
        # arrival, drive it toward release + recycle, and reap orphaned fleet-*
        # runners. Reconcile logic lives server-side (the worker is HTTP-only).
        #
        # POST /api/v1/system/worker_api/ci_runner_leases/advance
        #   Auth: mTLS (@current_worker — handled by BaseController)
        #   Body (optional): { account_id }  # scope the sweep to one account
        #   Response: { data: { accounts_swept, advanced, released, flagged,
        #                       errored, orphans_reaped } }
        class CiRunnerLeasesController < BaseController
          def advance
            summaries = target_accounts.map do |account|
              ::System::CiRunnerLeaseSweepService.run!(account: account)
            end

            render_success(aggregate(summaries).merge(accounts_swept: summaries.size))
          rescue StandardError => e
            Rails.logger.error("[CiRunnerLeasesController] sweep failed: #{e.class}: #{e.message}")
            render_error("ci_runner_lease_advance_failed: #{e.message}", :internal_server_error)
          end

          private

          def target_accounts
            if (id = params[:account_id].presence)
              Array(::Account.find_by(id: id))
            else
              ::Account.where(id: ::System::CiRunnerLease.active.select(:account_id).distinct)
            end
          end

          def aggregate(summaries)
            %i[advanced released flagged errored orphans_reaped].index_with do |key|
              summaries.sum { |summary| summary[key].to_i }
            end
          end
        end
      end
    end
  end
end
