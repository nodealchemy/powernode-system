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

        # IMP-a366d6fb6b80 - a second population on the same lane: an
        # assignment holding an SMB credential that has been "rotating" past
        # System::Storage::RotatingCredentialSweeper.window, i.e. the consumer
        # never confirmed the remount that would have retired it. It rides
        # THIS signal kind so the applier this lane already has
        # (DecisionEngine#reconcile_storage_assignment) runs the sweep; one
        # signal per assignment, whichever population(s) it is in. An
        # assignment that is only in this population is otherwise healthy, so
        # its payload says "reconcile" => false and the applier sweeps without
        # re-driving a mount. No staleness window applies: the overdue test IS
        # the window, and the credential's assignment can be mounted, disabled
        # or already reconciled, none of which stops the old samba user being
        # valid.
        def sense
          drift = drifting_assignments.to_h { |assignment| [ assignment.id, assignment ] }
          overdue = overdue_rotating_credentials

          drift.map { |id, assignment| build_signal(assignment, overdue[id]) } +
            (overdue.keys - drift.keys).map do |id|
              credentials = overdue[id]
              build_signal(credentials.first.storage_assignment, credentials, reconcile: false)
            end
        end

        private

        def drifting_assignments
          # IMP-e48612a32273 - .or(mount_credential_mismatch): same safety-
          # net reasoning as AssignmentReconciliationService.reconcile_instance!
          # - a mounted assignment whose consumer never actually remounted
          # after a rotation is invisible to pending_reconcile alone.
          ::System::StorageAssignment
            .pending_reconcile
            .or(::System::StorageAssignment.mount_credential_mismatch)
            .where(account: account)
            .where("last_status_at IS NULL OR last_status_at < ?", STALE_WINDOW.ago)
            .includes(:node_instance)
            .find_each.to_a
        end

        # { storage_assignment_id => [rotating credentials past the window] }.
        # A row with no rotating_since is included on purpose: the sweep stamps
        # it, which is what gives it a clock; leaving it out would leave it
        # unbounded.
        def overdue_rotating_credentials
          cutoff = Time.current - ::System::Storage::RotatingCredentialSweeper.window
          ::System::StorageCredential
            .rotating_overdue(cutoff)
            .joins(:storage_assignment)
            .merge(::System::StorageAssignment.where(account_id: account.id))
            .includes(storage_assignment: :node_instance)
            .group_by(&:storage_assignment_id)
        end

        def build_signal(assignment, overdue_credentials, reconcile: true)
          payload = {
            storage_assignment_id: assignment.id,
            node_instance_id: assignment.node_instance_id,
            status: assignment.status,
            last_status_at: assignment.last_status_at&.utc&.iso8601
          }
          if overdue_credentials.present?
            payload.merge!(
              node_instance_name: assignment.node_instance&.name,
              smb_rotation_overdue_credential_ids: overdue_credentials.map(&:id),
              smb_rotation_window_hours: (::System::Storage::RotatingCredentialSweeper.window / 1.hour).to_i
            )
          end
          payload[:reconcile] = false unless reconcile

          signal(
            kind: "system.storage_assignment_drift",
            severity: :medium,
            payload: payload,
            fingerprint: "storage_assignment_drift:#{assignment.id}"
          )
        end
      end
    end
  end
end
