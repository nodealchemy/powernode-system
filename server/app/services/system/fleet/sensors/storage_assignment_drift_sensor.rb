# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Periodic sweep that re-reconciles assignments stuck in pending /
      # degraded / failed for too long. Each StorageAssignment's own
      # after_commit triggers reconciliation on edit; this sensor is the
      # safety net for cases where the agent never responded or a backoff
      # window expired without a fresh edit.
      #
      # Wired into FleetAutonomyService as a registered sensor; runs on the
      # standard fleet sensor cadence (60s).
      class StorageAssignmentDriftSensor
        STALE_WINDOW = 5.minutes

        def self.scan(account: nil)
          new(account: account).scan
        end

        def initialize(account: nil)
          @account = account
        end

        def scan
          scope = ::System::StorageAssignment.pending_reconcile
          scope = scope.where(account: @account) if @account

          drifted = scope.where("last_status_at IS NULL OR last_status_at < ?", STALE_WINDOW.ago)
          drifted.find_each do |assignment|
            ::System::Storage::AssignmentReconciliationService.reconcile_assignment!(assignment)
          end

          {
            scanned: scope.count,
            drifted: drifted.count
          }
        end
      end
    end
  end
end
