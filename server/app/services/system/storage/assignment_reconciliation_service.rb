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
      # NFS is NOT covered by this method, and that omission is
      # deliberate, not "already handled elsewhere": record_failure! only
      # catches an EXCEPTION raised synchronously inside reconcile! (e.g.
      # CredentialIssuer#issue! raising), never an agent-side
      # storage.exports.apply task failure reported back asynchronously —
      # and NfsExportManager has no #reconcile! of its own to catch it
      # either. A stalled/failed NFS export is a real, separate gap; it is
      # out of scope for this change.
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
