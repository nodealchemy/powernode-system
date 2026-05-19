# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-side entry point for the daily compliance snapshot archival
        # job (SystemComplianceSnapshotJob). Generates a fresh snapshot per
        # account and emits a FleetEvent (kind="system.compliance.snapshot")
        # so the existing FleetEvent retention sweep handles pruning.
        #
        # Reference: audit plan P2.8d.
        class ComplianceController < BaseController
          def archive
            authorize_worker_permission!("system.compliance.archive")
            return if performed?

            result = ::System::Compliance::DailySnapshotArchivalService.run!
            render_success({
              snapshots_emitted: result.snapshots_emitted,
              accounts_failed: result.accounts_failed,
              errors: result.errors
            })
          end
        end
      end
    end
  end
end
