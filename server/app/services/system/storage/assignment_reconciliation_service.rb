# frozen_string_literal: true

module System
  module Storage
    # Drives StorageAssignment toward its target state.
    #
    # Triggers (each one calls reconcile_assignment!):
    #   * StorageAssignment after_commit on create or status-affecting update
    #   * Agent heartbeat reports a missing mount (heartbeat handler dispatches)
    #   * Periodic StorageAssignmentDriftSensor sweep
    #
    # Steps per assignment:
    #   1. Bail if not enabled (any mounted assignment that's now disabled
    #      gets an unmount task instead).
    #   2. Honor exponential backoff stored in error_message metadata.
    #   3. Ensure Sdwan::Peer exists (auto-enroll via Sdwan::PeerEnroller).
    #   4. Ensure StorageCredential exists + not expired (issue via
    #      CredentialIssuer, which also writes exports.d / samba user on
    #      the backend peer).
    #   5. Dispatch storage.mount task to the client node.
    class AssignmentReconciliationService
      BACKOFF_BASE = 30 # seconds
      BACKOFF_MAX = 30.minutes

      def self.reconcile_instance!(instance)
        ::System::StorageAssignment
          .pending_reconcile
          .where(node_instance_id: instance.id)
          .find_each { |a| reconcile_assignment!(a) }
      end

      def self.reconcile_assignment!(assignment)
        new(assignment: assignment).reconcile!
      end

      def initialize(assignment:)
        @assignment = assignment
      end

      def reconcile!
        if !@assignment.enabled? && @assignment.status == "mounted"
          dispatch_unmount!
          return
        end

        return unless @assignment.enabled?
        return if in_backoff?

        # Preserve error_message across this transition — it's where the
        # attempt counter + backoff_until from a prior failure live. Wiping
        # it here (the mark_status! default) would reset attempt to 1 on
        # every retry, pinning backoff at BACKOFF_BASE forever. It's only
        # cleared for real once the agent reports back success (see
        # NodeApi::StorageAssignmentsController#update_status).
        @assignment.mark_status!("provisioning", error_message: @assignment.error_message)

        ensure_peer!
        credential = ensure_credential!
        encryption_key = ensure_encryption_key! if @assignment.effective_encryption_mode != "none"

        dispatch_mount!(credential: credential, encryption_key: encryption_key)
      rescue StandardError => e
        record_failure!(e)
      end

      private

      def in_backoff?
        until_time = @assignment.error_message.to_s.match(/backoff_until:(\S+)/)&.[](1)
        return false unless until_time

        Time.parse(until_time) > Time.current
      rescue StandardError
        false
      end

      def ensure_peer!
        return unless @assignment.sdwan_network_id

        peer = ::Sdwan::Peer.find_by(
          node_instance_id: @assignment.node_instance_id,
          sdwan_network_id: @assignment.sdwan_network_id
        )
        return peer if peer

        ::Sdwan::PeerEnroller.call(
          network: @assignment.sdwan_network,
          node_instance: @assignment.node_instance
        )
      end

      def ensure_credential!
        active = @assignment.active_credential

        if active && !active.expired? && !active.needs_rotation?
          redispatch_stalled_smb_credential!(active)
          redispatch_stalled_nfs_reconcile!(active)
          return active
        end

        if active
          CredentialIssuer.new(assignment: @assignment).rotate!(active)
        else
          CredentialIssuer.new(assignment: @assignment).issue!
        end
      end

      # ensure_credential!'s expiry/needs_rotation? check only catches a
      # credential aging OUT — it says nothing about whether the backend
      # ever actually APPLIED the one that's currently "active". The DB
      # side (Vault-sealed, activate! run) and the agent side (samba-tool
      # actually ran) are two different systems of record, and only SMB has
      # a gap between them: the storage.smb_user.apply task dispatched when
      # this credential was issued/rotated can fail, abort, get cancelled,
      # or (if it was never dispatched at all — defensive) simply not
      # exist, leaving samba on the OLD password for up to ~89 days until
      # needs_rotation? finally trips a full rotation.
      #
      # Re-dispatches with provision_user! (action "create"), NEVER
      # rotate_user! (set_password): the agent's setSambaPassword only ever
      # runs `samba-tool user setpassword` (agent/internal/storage/
      # smb_user.go), so if the STALLED task was itself the original
      # first-issuance "create" — the samba-tool user was never actually
      # made — a set_password re-dispatch would fail on every single
      # reconcile tick forever. createSambaUser (smb_user.go) creates the
      # user if it's missing and falls through to setpassword if it
      # already exists, so "create" is the one dispatch that correctly
      # covers BOTH "never existed" and "exists, needs this password"
      # without knowing which case it's in — which is also why credential
      # and new_credential no longer need to name the same row twice.
      #
      # COVERAGE IS REACTIVE, not a background sweep: reconcile! only runs
      # when something calls it (the assignment's own after_commit, a
      # heartbeat reporting a missing mount, or the drift sensor) — and
      # pending_reconcile / the drift sensor both skip a `mounted`
      # assignment. A healthy, already-mounted assignment whose SMB
      # credential task failed is NOT proactively re-checked; it only gets
      # noticed the next time reconcile is triggered for some other reason
      # (e.g. the agent reports the mount missing, or the assignment is
      # updated).
      #
      # NFS gets the same treatment via the sibling
      # #redispatch_stalled_nfs_reconcile! below (IMP-9ffb9b2407da) — see
      # its own comment for why the mechanism has to differ (NFS's rebuild
      # is per-STORAGE, not per-credential, so there is no credential id in
      # the payload to match against the way smb_tasks_for_credential does).
      # IMP-eb6a3c299f4b increment 3 review — still correct after the
      # username-derivation scheme switch (increment 2) and PROVISION-then-
      # REVOKE rotation (increment 3): this always dispatches "create" for
      # `credential`'s OWN CURRENT username, whatever scheme it happens to
      # be on — it never compares against another credential's username or
      # assumes a particular derivation. createSambaUser (agent) is
      # idempotent regardless of the username's shape (old "node-<12hex>"
      # or new "n-<16hex>"), so this needed no change.
      def redispatch_stalled_smb_credential!(credential)
        return unless @assignment.file_storage&.smb?

        # Safe statuses: System::Task::STATUSES that mean "already applied"
        # (complete) or "still in flight, leave it alone" (Task.active's own
        # pending/scheduled/running) — an allowlist, not an enumeration of
        # the unsafe ones, so cancelled/failed/aborted and any future status
        # all redispatch by construction rather than by being individually
        # named.
        latest_status = smb_tasks_for_credential(credential).order(created_at: :desc).limit(1).pick(:status)
        return if latest_status && %w[pending scheduled running complete].include?(latest_status)

        ::System::Storage::SmbUserManager.new(assignment: @assignment).provision_user!(credential: credential)
      end

      def smb_tasks_for_credential(credential)
        ::System::Task
          .where(command: "storage.smb_user.apply", account_id: @assignment.account_id)
          .where(
            "options -> 'credential' ->> 'id' = :cred_id OR options -> 'new_credential' ->> 'id' = :cred_id",
            cred_id: credential.id
          )
      end

      # NFS counterpart of #redispatch_stalled_smb_credential! (IMP-9ffb9b2407da)
      # — same gap: a credential's DB-side status can be "active" while the
      # agent-side effect it was supposed to cause never actually landed —
      # the storage.exports.apply task dispatched when this credential was
      # granted (CredentialIssuer#issue!/#rotate! via NfsExportManager#grant!)
      # can fail, abort, get cancelled, or (pre-existing credentials from
      # before this change existed) simply never have been dispatched.
      #
      # UNLIKE SMB, there is no credential id anywhere IN THE PAYLOAD SHAPE
      # to match against — as of IMP-ba7956c5b38d, storage.exports.apply is
      # a per-STORAGE full rebuild (storage_id/account_id/export_path/
      # entries), not a per-credential dispatch. What NfsExportManager
      # #reconcile! DOES record (IMP-9ffb9b2407da) is
      # `included_credential_ids` — the credential ids that actually made
      # it into that rebuild's entries — and that membership list, not a
      # timestamp, is the right watermark. A TIMING check (was the latest
      # task created at/after this credential row) looks equivalent at
      # first but is wrong: disable an assignment, let a rebuild correctly
      # EXCLUDE it and complete (still created after the credential row,
      # like any other rebuild), then re-enable the SAME credential — a
      # timing check calls that "safe" even though it deliberately left the
      # peer out, and the peer would never get re-exported; the drift
      # sensor would re-run and skip forever. Membership doesn't have this
      # gap: a rebuild that excluded this credential simply won't list it.
      #
      # Safe-status handling mirrors SMB's allowlist, split in two because
      # the two cases need different tests:
      #   - pending/scheduled/running (#nfs_exports_task_in_flight?): skip
      #     unconditionally, no membership check needed. This is also the
      #     COALESCING guard — several assignments on the SAME storage can
      #     all reconcile in one tick (after_commit fan-out, a drift
      #     sweep); one in-flight rebuild is enough for all of them, since
      #     it reads live DB state at completion time and will reflect
      #     every assignment's current credential regardless of when it was
      #     dispatched. Without this, each assignment would fire its own
      #     #reconcile! and storm the storage's advisory lock / exports.d
      #     file with redundant rewrites.
      #   - complete: safe only if its included_credential_ids contains
      #     this credential's id.
      # Anything else (failed/aborted/cancelled/no task at all) redispatches.
      #
      # COVERAGE IS REACTIVE, not a background sweep — same caveat as SMB's
      # #redispatch_stalled_smb_credential!: this only runs when something
      # triggers reconcile! for this (or a sibling) assignment; a healthy,
      # already-mounted assignment whose export rebuild silently failed is
      # not proactively re-checked.
      #
      # Pre-existing credentials with no exports task at all (`latest` nil)
      # get ONE rebuild the first time they're reconciled under this
      # change. That's safe to run unconditionally: NfsExportManager#reconcile!
      # always computes its entries from live DB state, so a rebuild that
      # turns out to have been unnecessary is a no-op in effect, not a
      # regression — no separate de-duplication needed beyond the
      # coalescing check above.
      def redispatch_stalled_nfs_reconcile!(credential)
        storage = @assignment.file_storage
        return unless storage&.nfs?

        # A credential with no peer_ip can never be exported —
        # NfsExportManager#reconcile! itself skips it (WARN-and-continue,
        # see that method). Without this guard, EVERY reconcile tick for
        # this assignment would see "not included in the last rebuild" (it
        # never can be) and queue another rebuild, forever, for a row
        # nothing can fix by rebuilding again.
        if nfs_credential_peer_ip(credential).blank?
          Rails.logger.warn("[AssignmentReconciliationService] skipping NFS re-export check for assignment #{@assignment.id} / credential #{credential.id}: no peer_ip")
          return
        end

        return if nfs_exports_task_in_flight?(storage)

        latest = latest_exports_task_for(storage)
        return if latest&.status == "complete" && nfs_task_includes_credential?(latest, credential)

        ::System::Storage::NfsExportManager.reconcile!(storage: storage)
      end

      def nfs_credential_peer_ip(credential)
        credential.vault_credentials.dig("peer_ip") || credential.metadata["peer_ip"]
      end

      def nfs_task_includes_credential?(task, credential)
        Array(task.options["included_credential_ids"]).include?(credential.id)
      end

      def nfs_exports_task_in_flight?(storage)
        ::System::Task.active
          .where(account_id: @assignment.account_id, command: "storage.exports.apply")
          .where("options ->> 'storage_id' = :id", id: storage.id)
          .exists?
      end

      def latest_exports_task_for(storage)
        ::System::Task
          .where(command: "storage.exports.apply", account_id: @assignment.account_id)
          .where("options ->> 'storage_id' = :id", id: storage.id)
          .order(created_at: :desc, id: :desc) # tiebreaker for same-timestamp inserts
          .first
      end

      def ensure_encryption_key!
        existing = @assignment.mount_encryption_keys.active.first
        return existing if existing

        algorithm = algorithm_for_mode(@assignment.effective_encryption_mode)
        key = ::System::MountEncryptionKey.create!(
          storage_assignment: @assignment,
          node_instance_id: nil, # mount-wide; per-instance LUKS slots are v2 stretch
          algorithm: algorithm,
          escrowed: true
        )
        key.store_in_vault(material: SecureRandom.hex(32))
        ::System::MountEncryptionKey.find(key.id)
      end

      def algorithm_for_mode(mode)
        case mode
        when "fscrypt" then "fscrypt-v2"
        when "luks" then "aes-xts-plain64"
        when "client_side_aes" then "aes-256-gcm"
        else "fscrypt-v2"
        end
      end

      def dispatch_mount!(credential:, encryption_key:)
        return if mount_task_already_pending?

        payload = TaskPayloadBuilder.build_mount_payload(
          assignment: @assignment, credential: credential, encryption_key: encryption_key
        )

        ::System::Task.create!(
          account: @assignment.account,
          operable: @assignment.node_instance,
          command: "storage.mount",
          options: payload,
          status: "pending"
        )
      end

      # Reconcile can be triggered from three independent sources
      # (after_commit, heartbeat missing-mount, drift sweep) that can fire
      # in close succession — without this guard each one unconditionally
      # spawns its own storage.mount Task for the same assignment.
      def mount_task_already_pending?
        ::System::Task.active
          .where(account_id: @assignment.account_id, operable: @assignment.node_instance, command: "storage.mount")
          .where("options @> ?", { assignment_id: @assignment.id }.to_json)
          .exists?
      end

      def dispatch_unmount!
        return if unmount_task_already_pending?

        payload = TaskPayloadBuilder.build_unmount_payload(assignment: @assignment)

        ::System::Task.create!(
          account: @assignment.account,
          operable: @assignment.node_instance,
          command: "storage.unmount",
          options: payload,
          status: "pending"
        )
        @assignment.mark_status!("unmounting")
      end

      # Same race as mount_task_already_pending? above: two concurrent
      # reconcile triggers can both read status: "mounted" before either
      # one's mark_status!("unmounting") commits, so without this guard
      # each would spawn its own storage.unmount Task for the assignment.
      def unmount_task_already_pending?
        ::System::Task.active
          .where(account_id: @assignment.account_id, operable: @assignment.node_instance, command: "storage.unmount")
          .where("options @> ?", { assignment_id: @assignment.id }.to_json)
          .exists?
      end

      def record_failure!(error)
        attempt = (@assignment.error_message.to_s.match(/attempt:(\d+)/)&.[](1).to_i) + 1
        delay = [ BACKOFF_BASE * (2**(attempt - 1)), BACKOFF_MAX.to_i ].min
        backoff_until = (Time.current + delay).iso8601

        @assignment.mark_status!(
          "failed",
          error_message: "attempt:#{attempt} backoff_until:#{backoff_until} #{error.class}: #{error.message}"
        )
        Rails.logger.error("[StorageAssignment##{@assignment.id}] reconcile failed: #{error.class}: #{error.message}")
      end
    end
  end
end
