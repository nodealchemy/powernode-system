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
        #   Response: { data: { accounts_swept, accounts_gated, gates,
        #                       advanced, released, flagged, errored,
        #                       orphans_reaped } }
        #
        # accounts_swept counts accounts the sweep actually RAN for; gated
        # (halted/standby) accounts are broken out with per-gate counts —
        # the same honest-aggregate shape as FulfillmentController#sweep
        # (IMP-5fee957b75b5), added alongside the sweep's gates
        # (IMP-5f337c0f8e3e).
        class CiRunnerLeasesController < BaseController
          def advance
            summaries = target_accounts.map do |account|
              ::System::CiRunnerLeaseSweepService.run!(account: account)
            end

            gated, ran = summaries.partition { |s| s[:halted] || s[:standby] }
            render_success(
              aggregate(ran).merge(
                accounts_swept: ran.size,
                accounts_gated: gated.size,
                gates: gate_breakdown(gated)
              )
            )
          rescue StandardError => e
            Rails.logger.error("[CiRunnerLeasesController] sweep failed: #{e.class}: #{e.message}")
            render_error("ci_runner_lease_advance_failed: #{e.message}", :internal_server_error)
          end

          private

          def target_accounts
            return Array(::Account.find_by(id: params[:account_id])) if params[:account_id].present?

            # Sweep accounts with active leases OR orphaned fleet-* runners: a
            # recycled account can reach zero active leases while still carrying
            # offline runner rows that need reaping, so scoping on leases alone
            # would leave those orphans unreachable by the cron.
            account_ids = (
              ::System::CiRunnerLease.active.distinct.pluck(:account_id) +
              ::Devops::GitRunner.where("name LIKE 'fleet-%'").distinct.pluck(:account_id)
            ).compact.uniq
            ::Account.where(id: account_ids)
          end

          def aggregate(summaries)
            %i[advanced released flagged errored orphans_reaped].index_with do |key|
              summaries.sum { |summary| summary[key].to_i }
            end
          end

          # gate_breakdown lives on the shared WorkerApi::BaseController.
        end
      end
    end
  end
end
