# frozen_string_literal: true

module System
  module Storage
    # IMP-e48612a32273 — the SMB consumer remount-on-rotation chain. Called
    # from System::Task's after_update_commit hooks (command-specific logic
    # lives HERE, not in task.rb — review round 1). Three entry points, one
    # per event in the chain:
    #
    #   1. #dispatch_remount_for_completed_smb_task! — a storage.smb_user.apply
    #      task (create or set_password — never delete) completes. If its
    #      credential's assignment is already mounted, dispatch a remount so
    #      the consumer picks up the new password/username. Guards out the
    #      brand-new-assignment case (assignment.status is still
    #      "provisioning" the first time a samba task completes — the
    #      ordinary reconcile!'s own dispatch_mount! handles the first mount
    #      as it always has), AND (BLOCKER 3, review) skips entirely when
    #      mounted_credential_id already equals this credential's id — a
    #      completed create/set_password for a credential the consumer is
    #      ALREADY confirmed-mounted with (e.g. a stalled-task re-dispatch)
    #      has nothing to remount for.
    #
    #   2. #handle_completed_mount_task! — ANY storage.mount task completes.
    #      Records mounted_credential_id (the confirmation record every
    #      drift check and remount decision reads — see
    #      StorageAssignment#mount_credential_mismatch and
    #      AssignmentReconciliationService#dispatch_mount!) and, whenever
    #      that flip lands the assignment on its CURRENT active_credential,
    #      retires every OTHER still-"rotating" credential
    #      (CredentialIssuer#retire_rotating_smb_credentials!, state-
    #      derived, no metadata breadcrumb — covers rotate-rotate-confirm).
    #      Fires on ANY successful mount naming the active credential, not
    #      only remount:true (rework hole (a) — an assignment rotated while
    #      unmounted gets an ordinary first mount once re-enabled, and THAT
    #      mount is what confirms the rotation too).
    #
    #      ROLLOUT-SKEW GATE (review): neither the flip nor the retire runs
    #      on task-completion alone — an old (pre-remount-aware) agent
    #      ignores `remount`, runs a no-op `start` on an already-active
    #      unit, and reports complete regardless, which is exactly as true
    #      for a plain first mount whenever mounted_credential_id was never
    #      resolved. Both actions require the completion's OWN result to
    #      carry `mounted_credential_id` equal to the credential this task
    #      named — see #confirmed_credential_id's own comment. Missing or
    #      mismatched proof flips nothing: mounted_credential_id stays as-is
    #      so the drift/reconcile cadence keeps re-dispatching until the
    #      node's agent upgrades (or an operator intervenes), and
    #      error_message says so.
    #
    #   3. #handle_failed_mount_task! — a remount-flagged storage.mount task
    #      fails. Marks the assignment "degraded" (a pending_reconcile
    #      status) so the ordinary reconcile/drift sweep retries it — see
    #      StorageAssignment#mount_credential_mismatch's own comment for why
    #      a plain status change alone would not otherwise re-admit an
    #      already-"mounted" row. The old samba user(s) are untouched: #2
    #      never fires for a failed task, so nothing still "rotating" is
    #      retired — the consumer keeps working on its existing (old-
    #      username) session until a retry succeeds. Also tracks a
    #      consecutive-remount-failure counter in error_message (non-
    #      blocking review item) — see that method's own comment.
    #
    # SCOPING (security review): every id this class reads out of a task's
    # OWN options is re-resolved through a query scoped to that SAME task's
    # account_id, never trusted bare. A cross-account id appearing in a
    # task's options would mean something upstream is already broken; this
    # class does not compound that into a cross-account action — it no-ops
    # and logs instead of raising, so one malformed/stale task can't take
    # down the whole after_update_commit chain for every other task.
    class RemountCoordinator
      def self.dispatch_remount_for_completed_smb_task!(task)
        new(task: task).dispatch_remount_for_completed_smb_task!
      end

      def self.handle_completed_mount_task!(task)
        new(task: task).handle_completed_mount_task!
      end

      def self.handle_failed_mount_task!(task)
        new(task: task).handle_failed_mount_task!
      end

      def initialize(task:)
        @task = task
      end

      def dispatch_remount_for_completed_smb_task!
        credential_id = smb_task_acted_on_credential_id
        return unless credential_id

        credential = find_scoped_credential(credential_id)
        return log_scope_mismatch(credential_id) unless credential

        assignment = credential.storage_assignment
        # mounted_credential_id.present?, NOT assignment.status == "mounted"
        # (found via BLOCKER 2's fix): reconcile! unconditionally flips
        # status to "provisioning" the moment it runs, even when its OWN
        # dispatch_mount! call then skips dispatching anything (the
        # provisioning-race guard, same tick) — by the time THIS smb task
        # later completes, status can legitimately still read
        # "provisioning" for an assignment that really was already mounted.
        # mounted_credential_id is untouched by that transient flip: it is
        # ONLY ever set by a real prior mount confirmation, so it is the
        # correct "has this ever actually been mounted" signal here.
        return unless assignment&.mounted_credential_id.present?
        return if assignment.mounted_credential_id == credential.id # BLOCKER 3 — already confirmed on this credential, nothing to do

        ::System::Storage::AssignmentReconciliationService.dispatch_remount!(assignment)
      end

      # Rollout-skew review — a completion alone is NOT proof the consumer
      # actually picked up this credential: an old (pre-remount-aware) agent
      # ignores `remount`, runs a no-op `start` on an already-active unit,
      # and reports the task complete regardless. That is exactly as true
      # for a FIRST mount as for a remount whenever mounted_credential_id
      # was never resolved (e.g. the migration's backfill couldn't, or a
      # brand-new row) and the unit happens to already be active — so this
      # gate applies uniformly to every completion, not just remount:true.
      # The new agent's result carries positive proof instead: `Apply`
      # (agent/internal/storage/applier.go) is CONFIRMED only when it
      # actually restarted, or started a genuinely INACTIVE unit — never on
      # a no-op start — and StorageHandler#Execute
      # (agent/internal/runtime/tasks/handlers/storage.go) only then echoes
      # `mounted_credential_id` back in the completion result. Trust that,
      # and ONLY that: not just present, but equal to the credential THIS
      # task named (never trust a bare boolean or an unrelated id).
      #
      # Missing/mismatched proof does NOT fail anything or retry harder —
      # it simply withholds the flip: mounted_credential_id stays whatever
      # it already was, so StorageAssignment#mount_credential_mismatch keeps
      # reading this row as unconfirmed and the ordinary drift/reconcile
      # cadence keeps re-dispatching it, until either the node's agent is
      # upgraded and genuinely confirms, or an operator intervenes. Nothing
      # is deleted in the meantime. error_message names the cause so an
      # old-agent fleet is visible rather than silently stuck.
      def handle_completed_mount_task!
        assignment_id = @task.options["assignment_id"]
        assignment = find_scoped_assignment(assignment_id)
        return log_scope_mismatch(assignment_id) unless assignment

        credential_id = @task.options.dig("credential", "id")
        return unless credential_id

        credential = ::System::StorageCredential.find_by(id: credential_id, storage_assignment_id: assignment.id)
        return unless credential

        if confirmed_credential_id == credential_id
          assignment.update!(mounted_credential_id: credential.id)

          # rework hole (a) — confirm-and-retire on ANY mount that lands the
          # assignment on its CURRENT active credential, not only remount:true.
          return unless assignment.active_credential&.id == credential.id

          return ::System::Storage::CredentialIssuer.new(assignment: assignment).retire_rotating_smb_credentials!(credential)
        end

        # Review fix (1) — a completion that DIDN'T prove anything is only
        # a problem when it needed to: if the assignment already reads this
        # EXACT credential as mounted, nothing was actually at stake — the
        # agent legitimately reported `already_active: true` for a routine
        # reconcile that changed nothing, which is healthy, not an anomaly.
        # Only warn when the (missing/mismatched) confirmation would
        # actually have mattered, i.e. this completion was supposed to
        # prove a REAL change (a rotation, a first mount) and didn't.
        return if assignment.mounted_credential_id == credential_id

        note_unconfirmed_mount!(assignment)
      end

      def handle_failed_mount_task!
        return unless @task.options["remount"] == true

        assignment_id = @task.options["assignment_id"]
        assignment = find_scoped_assignment(assignment_id)
        return log_scope_mismatch(assignment_id) unless assignment

        # A plain first-mount failure (never remount:true) already goes
        # through reconcile!'s own record_failure!/backoff path unchanged —
        # this branch is only for the remount-specific retry loop.
        return unless assignment.status == "mounted"

        # Non-blocking review item — a consecutive-failure counter, parsed
        # from the assignment's own error_message. "remount_fail=" — NOT
        # "remount_attempt:" (review nit) — because #record_failure!'s own
        # counter already matches /attempt:(\d+)/; "remount_attempt:" would
        # collide with that same regex and read/increment the WRONG
        # counter. Includes the agent's actual reported failure text (e.g.
        # "...target is busy") so a run of these is legible without digging
        # into the task itself. Resets naturally once the agent's OWN
        # mount-lifecycle report clears error_message on a later success
        # (NodeApi::StorageAssignmentsController#update_status) — no new
        # reset logic needed here. No new backoff: the retry cadence is
        # unchanged. No new signal path either: StorageAssignmentDriftSensor
        # already sweeps "degraded" (pending_reconcile) once stale past its
        # existing window and emits system.storage_assignment_drift for it —
        # that seam already exists and needs nothing added.
        attempt = (assignment.error_message.to_s.match(/remount_fail=(\d+)/)&.[](1).to_i) + 1
        message = "remount_fail=#{attempt} #{@task.error_message.presence || 'remount failed'}"
        assignment.mark_status!("degraded", error_message: message)
      end

      private

      # Rollout-skew review — the only trustworthy source of "did this
      # completion prove a real mount": the agent's OWN completion result,
      # not the task's dispatch-time options (which only say what the
      # SERVER asked for, not what actually happened). node_api's
      # StatusController#complete_task stores the agent's `result:` param on
      # the "completed" event, not in `options` — see that controller's own
      # comment. A missing/malformed event or result is simply "no proof",
      # never an error to raise: an old agent's shape (no
      # mounted_credential_id key at all) is the EXPECTED failure mode this
      # exists to catch, not a bug. Array(...) (review fix (3)) — events is
      # a jsonb array defaulting to [], but never trust a column read bare.
      def confirmed_credential_id
        completed_event = Array(@task.events).reverse_each.find { |e| e["type"] == "completed" }
        completed_event&.dig("result", "mounted_credential_id")
      end

      # Review fix (2) — must not clobber #record_failure!'s "attempt:"/
      # "backoff_until:" tokens or #handle_failed_mount_task!'s
      # "remount_fail=" counter: this note is APPENDED, never a wholesale
      # replacement of error_message. Idempotent — a stalled assignment can
      # complete the SAME unconfirmed mount task's after_update_commit more
      # than once (a duplicate/racing event), so this checks whether the
      # note is already present before appending a second copy.
      def note_unconfirmed_mount!(assignment)
        note = "agent did not confirm mounted credential (agent upgrade needed?)"
        existing = assignment.error_message.to_s
        return if existing.include?(note)

        message = existing.presence ? "#{existing} #{note}" : note
        assignment.update!(error_message: message)
      end

      # For "create" the acted-on identity IS the `credential:` argument
      # SmbUserManager#provision_user! was called with (see
      # CredentialIssuer#rotate_smb_user!). For "set_password" the agent's
      # setSambaPassword always prefers NewCredential over Credential when
      # both are present (agent/internal/storage/smb_user.go) — new_credential
      # is the one whose password was actually just set.
      def smb_task_acted_on_credential_id
        case @task.options["action"]
        when "create" then @task.options.dig("credential", "id")
        when "set_password" then @task.options.dig("new_credential", "id")
        end
      end

      def find_scoped_credential(id)
        ::System::StorageCredential
          .joins(:storage_assignment)
          .merge(::System::StorageAssignment.where(account_id: @task.account_id))
          .find_by(id: id)
      end

      def find_scoped_assignment(id)
        return nil if id.blank?

        ::System::StorageAssignment.find_by(id: id, account_id: @task.account_id)
      end

      def log_scope_mismatch(id)
        Rails.logger.error(
          "[System::Storage::RemountCoordinator] task #{@task.id} (command #{@task.command}) " \
          "named id #{id.inspect} not found in its own account #{@task.account_id} — refusing"
        )
        nil
      end
    end
  end
end
