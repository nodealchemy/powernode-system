# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-side entry point for the scheduled platform-health duty
        # (campaign 01a07025 increment 3). The worker ticks this on a cron far
        # more frequent than the check actually needs
        # (extensions/system/worker/config/sidekiq_system.yml); this endpoint
        # does no work itself beyond delegating per-account to
        # ::System::Platform::ScheduledHealthCheckService, which is what
        # decides — from the `system.platform_health_check_interval_minutes`
        # SiteSetting, never a hardcoded interval — whether a given account is
        # actually due.
        #
        # Always returns 200 with a structured per-account summary, mirroring
        # FleetController#reconcile, so one account's failure never masks the
        # others'.
        class PlatformHealthController < BaseController
          def sweep
            accounts = scope_accounts
            results = ::System::Platform::ScheduledHealthCheckService.run_due_accounts!(accounts)

            render_success(account_count: results.size, results: results)
          end

          private

          # Same scoping as FleetController#reconcile: the worker's own
          # account when account-scoped, else every account with at least one
          # System::NodeInstance — avoids ticking accounts that never enabled
          # this extension's fleet features at all.
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
