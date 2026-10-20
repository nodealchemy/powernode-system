# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Best-effort post-enrolment seed cleanup sweep (D13). Its own endpoint, not
        # part of fleet/reconcile: it does synchronous provider I/O, so it has a
        # wall-clock budget and a small per-tick batch, and it is called WITHOUT
        # retry (a retried request would overlap itself). Rows are leased inside
        # EnrollmentSeedCleanup, so overlapping calls never double-process.
        class SeedCleanupController < BaseController
          # POST /api/v1/system/worker_api/seed_cleanup/sweep
          def sweep
            authorize_worker_permission!("system.fleet.reconcile")
            return if performed?

            # Fenced like every actuating loop: no provider writes on the standby
            # plane, whatever the state of the fleet agent (the reconcile tick's
            # own fence is not available when its agent is unseeded).
            unless ::System::Autonomy::ControlPlaneRole.active?
              return render_success(swept: 0, skipped: "standby")
            end

            deadline = ::System::EnrollmentSeedCleanup.monotonic_now + ::System::EnrollmentSeedCleanup::SWEEP_BUDGET
            swept = 0
            scope_accounts.each do |account|
              break if ::System::EnrollmentSeedCleanup.monotonic_now >= deadline
              next if ::Ai::Autonomy::KillSwitchService.new(account: account).halted?

              swept += ::System::EnrollmentSeedCleanup.sweep!(
                account: account, limit: ::System::EnrollmentSeedCleanup::SWEEP_LIMIT, deadline: deadline
              )
            rescue StandardError => e
              Rails.logger.warn("[SeedCleanup] account=#{account.id} sweep failed: #{e.class}")
            end

            render_success(swept: swept)
          end

          private

          def scope_accounts
            if current_worker.account?
              [ current_worker.account ]
            else
              account_ids = ::System::NodeInstance.joins(:node).distinct.pluck("system_nodes.account_id")
              Account.where(id: account_ids)
            end
          end
        end
      end
    end
  end
end
