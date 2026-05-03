# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-side entry point for cloud-state reconciliation.
        # The standalone worker (powernode-worker@default) hits this endpoint
        # on an hourly cron via SystemCloudSyncJob; the controller iterates
        # active provider regions per account in scope and delegates to
        # ::System::CloudSyncService.sync_region_instances for each.
        #
        # Reference: comprehensive stabilization sweep P2.1.
        class CloudSyncController < BaseController
          # Runs one cloud-sync tick across either:
          #   - the worker's own account (worker_account.present?)
          #   - all accounts with active provider connections (system worker)
          #
          # Always returns 200 with a structured per-account summary so a
          # mid-tick failure on one account doesn't take down the whole loop.
          # Per-region failures inside an account are also rescued so a single
          # broken cloud connection doesn't block other regions.
          def reconcile
            authorize_worker_permission!("system.cloud_sync.reconcile")
            return if performed?

            accounts = scope_accounts
            results = accounts.map do |account|
              sync_account(account)
            rescue StandardError => e
              Rails.logger.error("[CloudSync] account=#{account.id} failed: #{e.class}: #{e.message}")
              { account_id: account.id, ok: false, error: e.message }
            end

            render_success({
              tick_count: results.size,
              results: results
            })
          end

          private

          # Iterates regions for one account; rescues per-region so a slow
          # or down provider doesn't block the rest.
          #
          # Region selection: account's enabled provider connections imply
          # which providers the account is authorized for. Only sync regions
          # belonging to those providers (avoids 403s on regions whose
          # connection has been disabled).
          def sync_account(account)
            authorized_provider_ids = ::System::ProviderConnection
              .where(account_id: account.id, enabled: true)
              .distinct
              .pluck(:provider_id)

            regions = ::System::ProviderRegion
              .where(account_id: account.id, provider_id: authorized_provider_ids, enabled: true)

            synced_total = 0
            updated_total = 0
            errors = []

            regions.find_each do |region|
              result = ::System::CloudSyncService.sync_region_instances(region: region, account: account)
              if result.success?
                synced_total += result.data[:synced_count].to_i
                updated_total += result.data[:updated_count].to_i
              else
                errors << { region_id: region.id, error: result.error }
              end
            rescue StandardError => e
              Rails.logger.error("[CloudSync] account=#{account.id} region=#{region.id} failed: #{e.class}: #{e.message}")
              errors << { region_id: region.id, error: "#{e.class}: #{e.message}" }
            end

            {
              account_id: account.id,
              ok: errors.empty?,
              region_count: regions.count,
              synced_count: synced_total,
              updated_count: updated_total,
              errors: errors
            }
          end

          # If the worker is account-scoped, only its account is reconciled.
          # Otherwise (system worker), every account with at least one enabled
          # provider connection gets a tick. The latter is gated by the
          # explicit `system.cloud_sync.reconcile` permission.
          def scope_accounts
            if current_worker.account?
              [current_worker.account]
            else
              account_ids = ::System::ProviderConnection
                .where(enabled: true)
                .distinct
                .pluck(:account_id)
              Account.where(id: account_ids)
            end
          end
        end
      end
    end
  end
end
