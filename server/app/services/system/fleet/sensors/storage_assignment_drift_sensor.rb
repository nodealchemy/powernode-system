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
        OVERDUE_FINGERPRINT_PREFIX = "storage_smb_rotation_overdue"

        # IMP-a366d6fb6b80 - a second check on the same kind: an assignment
        # holding an SMB credential that has been "rotating" past
        # System::Storage::RotatingCredentialSweeper.window, i.e. the consumer
        # never confirmed the remount that would have retired it. It rides THIS
        # signal kind so the applier the lane already has
        # (DecisionEngine#reconcile_storage_assignment) runs the sweep, but it
        # is its OWN signal with its OWN fingerprint, never merged into the
        # drift signal. The drift fingerprint accrues ineffective outcomes for
        # a node whose reconcile keeps failing, and three of them force that
        # fingerprint to require_approval (F3-11): sharing it would strand this
        # bound behind an operator for exactly the unhealthy nodes it exists
        # for, and let this check pollute the drift lane's history. Separate
        # fingerprints mean each is scored on its own outcome: a retirement
        # makes this one disappear (effective); a failed one is applied:false
        # and never scored, and the sweeper raises its own alert.
        #
        # Its payload says "reconcile" => false: the assignment may be healthy
        # and mounted, so the applier sweeps without re-driving its mount. No
        # staleness window applies - the overdue test IS the window.
        def sense
          drifting_assignments.map { |assignment| build_drift_signal(assignment) } +
            overdue_rotating_credentials.map { |_id, credentials| build_overdue_signal(credentials) }
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

        # { storage_assignment_id => [rotating credentials past the window] },
        # for SMB storages only: the sweep has nothing to act on for a
        # credential whose storage is NFS or no longer resolves, and signalling
        # it every tick would only manufacture ineffective outcomes. A row with
        # no rotating_since is included on purpose: the sweep stamps it, which
        # is what gives it a clock. The storage is a hand-written lookup, not
        # an association, so it is resolved per assignment; the set is empty in
        # steady state.
        def overdue_rotating_credentials
          cutoff = Time.current - ::System::Storage::RotatingCredentialSweeper.window
          ::System::StorageCredential
            .rotating_overdue(cutoff)
            .joins(:storage_assignment)
            .merge(::System::StorageAssignment.where(account_id: account.id))
            .includes(storage_assignment: :node_instance)
            .group_by(&:storage_assignment_id)
            .select { |_id, credentials| credentials.first.storage_assignment.file_storage&.smb? }
        end

        def build_drift_signal(assignment)
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

        def build_overdue_signal(credentials)
          assignment = credentials.first.storage_assignment
          signal(
            kind: "system.storage_assignment_drift",
            severity: :medium,
            payload: {
              storage_assignment_id: assignment.id,
              node_instance_id: assignment.node_instance_id,
              node_instance_name: assignment.node_instance&.name,
              status: assignment.status,
              smb_rotation_overdue_credential_ids: credentials.map(&:id),
              smb_rotation_window_hours: (::System::Storage::RotatingCredentialSweeper.window / 1.hour).to_i,
              reconcile: false
            },
            fingerprint: "#{OVERDUE_FINGERPRINT_PREFIX}:#{assignment.id}"
          )
        end
      end
    end
  end
end
