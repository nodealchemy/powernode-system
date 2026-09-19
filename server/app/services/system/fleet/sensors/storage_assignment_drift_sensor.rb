# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects assignments stuck in pending / provisioning / degraded /
      # failed for too long. Each StorageAssignment's own after_commit
      # triggers reconciliation on edit; this sensor is the safety net for
      # cases where the agent never responded or a backoff window expired
      # without a fresh edit.
      #
      # Pure read-side per the BaseSensor contract: it only EMITS
      # system.storage_assignment_drift signals. Reconciliation runs through
      # the DecisionEngine's remediation applier once the
      # system.storage_assignment_reconcile gate proceeds (audit F3-07 — the
      # previous version swept and mutated directly, and was never invoked).
      class StorageAssignmentDriftSensor < BaseSensor
        STALE_WINDOW = 5.minutes

        def sense
          # IMP-e48612a32273 — .or(mount_credential_mismatch): same safety-
          # net reasoning as AssignmentReconciliationService.reconcile_instance!
          # — a mounted assignment whose consumer never actually remounted
          # after a rotation is invisible to pending_reconcile alone.
          ::System::StorageAssignment
            .pending_reconcile
            .or(::System::StorageAssignment.mount_credential_mismatch)
            .where(account: account)
            .where("last_status_at IS NULL OR last_status_at < ?", STALE_WINDOW.ago)
            .find_each.map do |assignment|
            signal(
              kind: "system.storage_assignment_drift",
              severity: :medium,
              payload: {
                storage_assignment_id: assignment.id,
                node_instance_id: assignment.node_instance_id,
                status: assignment.status,
                last_status_at: assignment.last_status_at&.utc&.iso8601
              },
              fingerprint: "storage_assignment_drift:#{assignment.id}"
            )
          end
        end
      end
    end
  end
end
