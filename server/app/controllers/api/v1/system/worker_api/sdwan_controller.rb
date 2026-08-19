# frozen_string_literal: true

# Worker-API endpoints for SDWAN background work. v1 has only the
# 90-day reaper for revoked Sdwan::UserDevice rows (the audit retention
# promised in slice 4). Future work: drift-recovery sweep, key-rotation
# scheduler tick.
#
# Slice 5 (deferred reaper) of the SDWAN plan.
module Api
  module V1
    module System
      module WorkerApi
        class SdwanController < BaseController
          AUDIT_RETENTION = 90.days

          # POST /api/v1/system/worker_api/sdwan/reap_user_devices
          #
          # Walks revoked user-device rows older than AUDIT_RETENTION,
          # destroys the Vault credential, then hard-deletes the row.
          # Returns reaped_count for the worker job's log line.
          def reap_user_devices
            cutoff = AUDIT_RETENTION.ago
            scope = ::Sdwan::UserDevice.where("revoked_at < ?", cutoff)

            reaped = 0
            errors = []

            scope.find_each do |device|
              # Best-effort Vault cleanup — VaultCredential's after_destroy
              # callback handles this when vault_path is set, but we call
              # explicitly so a Vault outage doesn't silently leak the row.
              begin
                if device.vault_path.present?
                  ::Security::VaultClient.delete_secret(device.vault_path)
                end
              rescue StandardError => e
                errors << { device_id: device.id, error: e.message }
                Rails.logger.warn "[Sdwan::ReapUserDevicesJob] vault delete failed for #{device.id}: #{e.message}"
              end

              device.destroy
              reaped += 1
            rescue StandardError => e
              errors << { device_id: device.id, error: e.message }
              Rails.logger.error "[Sdwan::ReapUserDevicesJob] destroy failed for #{device.id}: #{e.message}"
            end

            render_success(
              reaped_count: reaped,
              error_count: errors.size,
              errors: errors,
              cutoff: cutoff.iso8601
            )
          end

          # POST /api/v1/system/worker_api/sdwan/flow_sample_retention_sweep
          #
          # IMP-b24afe85a309 — ages out system_sdwan_flow_samples, the
          # highest-volume table in the extension, which previously had no
          # retention path at all. The window is DB-driven and the deletes are
          # batched and bounded; see Sdwan::FlowSampleRetentionService for why
          # both matter on a table this size.
          #
          # Same permission as the fleet retention sweep — this is maintenance
          # reconciliation, not an SDWAN control-plane mutation.
          def flow_sample_retention_sweep
            authorize_worker_permission!("system.fleet.reconcile")
            return if performed?

            render_success(::Sdwan::FlowSampleRetentionService.call)
          end
        end
      end
    end
  end
end
