# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-side entry point for the FleetAutonomyService reconcile tick.
        # The standalone worker (powernode-worker@default) hits this endpoint
        # on a 60s cron; the controller does no work itself other than
        # delegating to ::System::Fleet::FleetAutonomyService.tick! per
        # account in scope.
        #
        # Reference: Golden Eclipse plan M7 — system_fleet_reconcile_job.
        class FleetController < BaseController
          # Runs one reconcile tick across either:
          #   - the worker's own account (worker_account.present?)
          #   - all active accounts (when worker is "system-scoped")
          #
          # Always returns 200 with a structured per-account summary so a
          # mid-tick failure on one account doesn't take down the whole loop.
          def reconcile
            authorize_worker_permission!("system.fleet.reconcile")
            return if performed?

            accounts = scope_accounts
            results = accounts.map do |account|
              account_id = account.id
              tick_result = ::System::Fleet::FleetAutonomyService.tick!(account: account)
              { account_id: account_id }.merge(tick_result)
            rescue StandardError => e
              Rails.logger.error("[FleetReconcile] account=#{account.id} failed: #{e.class}: #{e.message}")
              { account_id: account.id, ok: false, error: e.message }
            end

            render_success({
              tick_count: results.size,
              results: results
            })
          end

          # POST /api/v1/system/worker_api/fleet/retention_sweep
          # Nightly sweep — drops FleetEvents older than the configured
          # retention window. Critical-severity events get a longer
          # retention bonus so audit trails survive routine cleanup.
          def retention_sweep
            authorize_worker_permission!("system.fleet.reconcile")
            return if performed?

            retention_days = (ENV["POWERNODE_FLEET_EVENT_RETENTION_DAYS"] || 90).to_i.clamp(7, 3650)
            critical_days = (ENV["POWERNODE_FLEET_EVENT_CRITICAL_RETENTION_DAYS"] || 365).to_i.clamp(retention_days, 3650)

            routine_cutoff = retention_days.days.ago
            critical_cutoff = critical_days.days.ago

            deleted_routine = ::System::FleetEvent
              .where("emitted_at < ?", routine_cutoff)
              .where(severity: %w[low medium])
              .delete_all
            deleted_critical = ::System::FleetEvent
              .where("emitted_at < ?", critical_cutoff)
              .where(severity: %w[high critical])
              .delete_all

            render_success(
              retention_days: retention_days,
              retention_critical_days: critical_days,
              deleted_routine: deleted_routine,
              deleted_critical: deleted_critical,
              deleted_total: deleted_routine + deleted_critical
            )
          end

          # POST /api/v1/system/worker_api/fleet/events
          # Accepts a batch of agent-side telemetry events. Each entry becomes
          # a System::FleetEvent row + ActionCable broadcast. The agent
          # batches events to reduce HTTP overhead when the fleet is busy.
          #
          # Permission: system.fleet.reconcile (same surface as the tick).
          # Body shape: { events: [{ kind, severity, payload, ... }, ...] }
          def events
            authorize_worker_permission!("system.fleet.reconcile")
            return if performed?

            account = scope_accounts.first
            return render_error("no account in scope", 422) unless account

            entries = Array(params[:events])
            return render_error("events: required", 422) if entries.empty?

            written = 0
            entries.each do |entry|
              ::System::Fleet::EventBroadcaster.emit!(
                account: account,
                kind: entry[:kind] || entry["kind"],
                severity: (entry[:severity] || entry["severity"] || "low"),
                payload: entry[:payload] || entry["payload"] || {},
                source: entry[:source] || entry["source"] || "agent",
                correlation_id: entry[:correlation_id] || entry["correlation_id"],
                node_instance_id: entry[:instance_id] || entry["instance_id"]
              )
              written += 1
            end

            render_success(written: written)
          end

          private

          # If the worker is account-scoped, only its account is reconciled.
          # If it's a system worker, every account with active node instances
          # gets a tick. The "system worker" path is gated by the explicit
          # system.fleet.reconcile permission so it cannot be invoked unless
          # the worker has the permission seeded.
          def scope_accounts
            if current_worker.account?
              [current_worker.account]
            else
              # Find accounts with at least one System::NodeInstance — avoids
              # ticking idle accounts every 60s.
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
