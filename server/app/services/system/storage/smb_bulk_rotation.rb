# frozen_string_literal: true

module System
  module Storage
    # IMP-2ceb2bd37e71 — OPERATOR-RUN bulk rotation of every live SMB credential
    # (SMB remediation step 3: before c9eb9e72 a password could sit in a
    # historical task row, so every live credential is rotated once).
    #
    # This is tooling for a person to run (rails system:storage:smb_rotate_all).
    # The dev loop must never run #execute! against a live environment; its
    # specs drive it against the test database only.
    #
    # The shape is deliberately the bulk-operation shape the project requires:
    #   - #plan is READ-ONLY, states the count, and is the default.
    #   - #execute! needs the operator to restate that count (confirm_count) —
    #     a stale or typo'd number refuses, so the confirm is for THIS plan.
    #   - #execute! is gated on the step-1 preflight (SmbRotationPreflight): only
    #     a safe_to_rotate verdict proceeds. The gate is evaluated at execute
    #     time, not at plan time, so a fleet that changed in between is caught.
    #   - Rotation reuses CredentialIssuer#rotate! unchanged, so everything the
    #     single-credential path guarantees (row lock, successor ordering,
    #     deferred old-user retirement until the consumer's remount confirms)
    #     holds per item. This class adds no rotation logic of its own.
    #   - It STOPS at the first SERVER-SIDE failure (vault, database, no backend
    #     configured). It cannot see an AGENT-side failure: rotation only
    #     enqueues tasks, so a broken agent shows up later, in #verify. That is
    #     what limit: is for — rotate a pilot (LIMIT=1), verify it converged,
    #     then run the rest.
    #   - Only enabled assignments in a remount-capable state (mounted or
    #     degraded) with a confirmed mounted_credential_id are PLANNED. A row
    #     with no confirmed mount can never be remounted by RemountCoordinator
    #     or the drift sweep, so rotating it would lock its consumer out once the
    #     old user is retired; those are reported as blocked/excluded for the
    #     operator to handle, never rotated here.
    #   - #verify is read-only and re-runnable; it checks, per consumer, that the
    #     remount the rotation triggered was CONFIRMED by the agent
    #     (mounted_credential_id == the active credential), not merely dispatched.
    #
    # NOT covered, by design: it does not wait for agents. Rotation dispatches
    # tasks; the remount is dispatched by RemountCoordinator when the agent
    # completes them, and a consumer that never confirms is re-dispatched by the
    # drift sweep (StorageAssignment.mount_credential_mismatch). #verify is how
    # the operator sees which consumers have not converged yet.
    #
    # Nothing here reads or returns credential material: rows carry ids,
    # statuses and timestamps only.
    class SmbBulkRotation
      class Refused < StandardError; end

      # An empty `since` plans every live credential. Resuming an interrupted
      # run passes the start time that run printed, which skips credentials
      # already rotated at or after it.
      def initialize(since: nil, limit: nil, preflight: SmbRotationPreflight, issuer: CredentialIssuer, clock: Time)
        @since = since
        @limit = limit
        @preflight = preflight
        @issuer = issuer
        @clock = clock
      end

      Plan = Struct.new(:generated_at, :since, :limit, :rows, :skipped_recent, :excluded, :total_eligible, keyword_init: true) do
        def count
          rows.size
        end
      end

      Result = Struct.new(:started_at, :rotated, :skipped, :failed, :not_attempted, keyword_init: true)

      VerifyReport = Struct.new(:generated_at, :rows, :counts, :rotating, :stuck_rotating, :excluded, :verdict, keyword_init: true)

      REMOUNT_CAPABLE_STATUSES = %w[mounted degraded].freeze

      def plan
        rows = []
        skipped = 0
        excluded = []
        live_assignments.each do |assignment|
          credential = assignment.active_credential
          next unless credential

          reason = exclusion_reason(assignment)
          if reason
            excluded << { assignment_id: assignment.id, assignment_status: assignment.status, reason: reason }
            next
          end

          if @since && credential.last_rotated_at && credential.last_rotated_at >= @since
            skipped += 1
            next
          end

          rows << {
            assignment_id: assignment.id,
            account_id: assignment.account_id,
            file_storage_id: assignment.file_storage_id,
            node_instance_id: assignment.node_instance_id,
            credential_id: credential.id,
            credential_status: credential.status,
            last_rotated_at: credential.last_rotated_at&.iso8601,
            mounted_credential_id: assignment.mounted_credential_id
          }
        end

        total = rows.size
        rows = rows.first(@limit) if @limit
        Plan.new(generated_at: @clock.current, since: @since, limit: @limit, rows: rows, skipped_recent: skipped,
                 excluded: excluded, total_eligible: total)
      end

      # Yields { event: "start", started_at:, total: } once before the first
      # rotation (the value an interrupted run resumes from), then one event per
      # attempted item: { index:, total:, assignment_id:, outcome:
      # "rotated"|"skipped"|"failed" }.
      def execute!(confirm_count:)
        current = plan
        confirm = confirm_count.to_s.strip
        if confirm.empty?
          raise Refused, "confirm required: this would rotate #{current.count} SMB credential(s); " \
                         "re-run with CONFIRM=#{current.count} to proceed"
        end
        unless confirm == current.count.to_s
          raise Refused, "confirm #{confirm.inspect} does not match the planned count #{current.count}; " \
                         "the fleet may have changed — re-run the dry run and confirm its count"
        end
        raise Refused, "nothing to rotate" if current.count.zero?

        report = @preflight.call
        unless report.verdict == "safe_to_rotate"
          raise Refused, "preflight verdict is #{report.verdict}, not safe_to_rotate; " \
                         "run rails system:storage:smb_rotation_preflight and resolve it first"
        end

        started_at = @clock.current
        result = Result.new(started_at: started_at, rotated: [], skipped: [], failed: [], not_attempted: 0)
        yield({ event: "start", started_at: started_at, total: current.count }) if block_given?
        current.rows.each_with_index do |row, index|
          outcome = rotate_one(row)
          bucket = outcome[:error_class] ? result.failed : (outcome[:skipped] ? result.skipped : result.rotated)
          bucket << outcome
          yield({ index: index + 1, total: current.count, assignment_id: row[:assignment_id],
                  outcome: outcome[:error_class] ? "failed" : (outcome[:skipped] ? "skipped" : "rotated") }) if block_given?
          if outcome[:error_class]
            result.not_attempted = current.count - index - 1
            break
          end
        end
        result
      end

      def verify
        rows = []
        excluded = []
        live_assignments.each do |assignment|
          credential = assignment.active_credential
          next unless credential

          reason = exclusion_reason(assignment)
          if reason
            excluded << { assignment_id: assignment.id, assignment_status: assignment.status, reason: reason }
            next
          end
          rows << verify_row(assignment, credential)
        end

        counts = rows.group_by { |row| row[:state].to_sym }.transform_values(&:size)
        counts = { confirmed: 0, stale_mount: 0 }.merge(counts)
        smb_credentials = ::System::StorageCredential.where(storage_assignment_id: live_assignments.select(:id))
        rotating = smb_credentials.rotating.count
        stuck = smb_credentials.rotating_overdue(@clock.current - RotatingCredentialSweeper.window).count
        complete = rows.any? && counts[:stale_mount].zero? && rotating.zero?

        VerifyReport.new(generated_at: @clock.current, rows: rows, counts: counts, rotating: rotating,
                         stuck_rotating: stuck, excluded: excluded, verdict: complete ? "complete" : "pending")
      end

      private

      # SMB storages are FileManagement::Storage rows (the assignment's own
      # file_storage lookup is account-scoped, so the join is by id here).
      def live_assignments
        ::System::StorageAssignment.where(
          file_storage_id: ::FileManagement::Storage.where(provider_type: "smb").select(:id)
        ).order(:created_at, :id)
      end

      def rotate_one(row)
        assignment = ::System::StorageAssignment.find(row[:assignment_id])
        credential = assignment.storage_credentials.find(row[:credential_id])
        successor = @issuer.new(assignment: assignment).rotate!(credential)
        # rotate! returns the existing successor (or the same row) when the
        # credential was no longer rotatable under its lock — a lost race, not
        # a rotation. Do not count that as rotated.
        if successor.id == credential.id || %w[issued active].include?(credential.reload.status)
          return { assignment_id: row[:assignment_id], skipped: true, reason: "no_longer_rotatable" }
        end

        { assignment_id: row[:assignment_id], old_credential_id: credential.id, new_credential_id: successor.id }
      rescue StandardError => e
        # The exception CLASS only. A message from the vault, the database or an
        # agent is not guaranteed free of row or credential content (a Postgres
        # DETAIL line echoes the failing row), so it is never printed.
        { assignment_id: row[:assignment_id], error_class: e.class.name }
      end

      # Nil when the assignment can be rotated and remounted by the platform.
      def exclusion_reason(assignment)
        return "disabled" unless assignment.enabled
        return "status_#{assignment.status}" unless REMOUNT_CAPABLE_STATUSES.include?(assignment.status)
        return "no_confirmed_mount" if assignment.mounted_credential_id.blank?

        nil
      end

      def verify_row(assignment, credential)
        state =
          if assignment.mounted_credential_id == credential.id
            "confirmed"
          else
            # A planned assignment always had a confirmed mount (see
            # #exclusion_reason), so a mismatch means it is still on the
            # superseded credential until the agent confirms the remount.
            "stale_mount"
          end

        { assignment_id: assignment.id, node_instance_id: assignment.node_instance_id,
          active_credential_id: credential.id, mounted_credential_id: assignment.mounted_credential_id,
          assignment_status: assignment.status, state: state }
      end
    end
  end
end
