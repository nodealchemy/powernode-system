# frozen_string_literal: true

module System
  module Storage
    # Issues + rotates + revokes per-instance storage credentials.
    #
    # Flow:
    #   1. Resolve (or auto-enroll) Sdwan::Peer for (instance, network)
    #   2. Assemble plain-hash context for the provider
    #   3. Call provider.issue_node_credential — pure data return
    #   4. Persist System::StorageCredential, seal payload in Vault
    #   5. Side-effects: NfsExportManager#grant! or SmbUserManager#provision_user!
    #      depending on provider_type
    #
    # Avoids the @vault_credentials cache reload bug
    # (feedback_vault_credential_reload_bug.md) by re-fetching the credential
    # via Model.find(id) after store_in_vault rather than calling reload.
    class CredentialIssuer
      class IssuanceError < StandardError; end

      def initialize(assignment:)
        @assignment = assignment
        @storage = assignment.file_storage
      end

      def issue!
        credential = issue_credential_row!
        materialize_backend_side!(credential)
        credential.activate!
        credential
      end

      # Rotation REPLACES the same backend identity — it is not "issue a new
      # one, then tear down the old one as if it were unrelated". This
      # matters concretely for SMB: StorageProviders::SmbStorage#issue_node_credential
      # derives the samba-tool username DETERMINISTICALLY from
      # node_instance_id, so the credential this creates shares its username
      # with the one being rotated out. The backend must run exactly one
      # set_password against that shared user — never the "create" dispatch
      # #issue! uses for a brand-new identity, and never a delete of that
      # same username afterward (the bug this method used to have: calling
      # #issue! here dispatched "create" — which the agent's idempotent
      # createSambaUser falls through to setpassword on since the user
      # already exists, so this accidentally worked — but then paired it
      # with an unconditional #revoke! on the OLD credential, which
      # deprovisioned that SAME username: every rotation deleted the SMB
      # user it had just set a new password on).
      # Row-locked + status-rechecked: two callers can legitimately race here
      # (the operator's rotate_credential action, AssignmentReconciliationService
      # #ensure_credential! running from a heartbeat/drift sweep, and any
      # future caller) all resolving the SAME @assignment.active_credential
      # before either has written anything. Without the lock, both proceed to
      # issue an independent new row and dispatch an independent set_password
      # — samba ends up with whichever task's password the agent applied
      # last, while active_credential serves whichever row committed last;
      # the two can disagree. #with_lock (transaction + SELECT ... FOR
      # UPDATE) serializes them on the credential ROW being rotated: the
      # second caller blocks until the first's entire rotation (issue +
      # dispatch + activate + revoke) has committed, then re-reads this same
      # row (with_lock reloads under the lock) and finds it no longer
      # rotatable — so it returns the FIRST caller's successor instead of
      # racing to mint a second one.
      def rotate!(credential)
        credential.with_lock do
          return existing_successor_or(credential) unless rotatable?(credential)

          credential.mark_rotating!
          new_cred = issue_credential_row!

          if @storage.smb?
            SmbUserManager.new(assignment: @assignment).rotate_user!(credential: credential, new_credential: new_cred)
          else
            materialize_backend_side!(new_cred)
          end
          new_cred.activate!

          # IMP-ba7956c5b38d — skip_nfs_reconcile: true, not the default
          # false: NfsExportManager#grant! above (via #materialize_backend_side!)
          # already ran a FULL exports-file rebuild that reflects the
          # post-rotation state correctly — at that point `credential` was
          # already "rotating" (excluded from StorageAssignment#active_credential)
          # and `new_cred` was already "issued" (included) — so a second
          # rebuild from this #revoke! call would be redundant, not
          # incorrect. Chose ONE rebuild per rotation over two idempotent
          # ones since avoiding it is this cheap; skipped only for NFS
          # (the flag has no effect on the SMB branch).
          revoke!(credential, successor: new_cred, skip_nfs_reconcile: true)
          new_cred
        end
      end

      # successor: the StorageCredential replacing this one, if this call is
      # part of a rotation. nil means a TRUE removal — the last live
      # credential for this backend identity, or the assignment being torn
      # down — and deprovisioning always runs for that case.
      #
      # ORDERING: the credential row itself is revoked (DB status ->
      # "revoked") synchronously, at the end of this method, exactly as
      # before this change — there is no task-completion callback for
      # storage.smb_user.apply to gate on (unlike storage.chown's
      # chown_complete). This is safe for the set_password/rotate path
      # specifically because the agent's setSambaPassword ALWAYS prefers
      # NewCredential over Credential when both are present
      # (agent/internal/storage/smb_user.go) — the old credential's ref
      # in the payload is validated for shape but never actually
      # dereferenced once a successor exists, so revoking it immediately
      # cannot 404 anything the live task will fetch. What DOES need to
      # stay fetchable through the whole flow is the SUCCESSOR — see
      # credential_issuer_spec.rb's ordering spec, which asserts the
      # node_api endpoint still serves new_cred's material, live, AFTER
      # #rotate! (including this revoke) has returned.
      # defer_nfs_reconcile: IMP-e88b38770d13 review round 1 — a destroy-
      # driven caller (StorageCredential#deprovision_before_destroy!) passes
      # true to skip the NFS dispatch entirely here and instead rebuild the
      # WHOLE file from live DB state once the row (and possibly its
      # storage_assignment) is actually gone — see StorageCredential's
      # after_destroy_commit. Necessary specifically for a destroy/cascade:
      # reconciling before the row (or an assignment/sibling still mid-
      # cascade) is truly gone could still see it, or waste a rebuild on a
      # not-yet-final intermediate state.
      #
      # skip_nfs_reconcile: IMP-ba7956c5b38d — distinct from defer_nfs_reconcile
      # (which means "someone else will rebuild later"): this means "no
      # further rebuild is needed at all", used by #rotate! because
      # #materialize_backend_side!'s #grant! call already ran a full,
      # correct rebuild for the new credential moments earlier — see
      # #rotate!'s own comment.
      #
      # ORDERING (IMP-ba7956c5b38d) — credential.revoke! (status ->
      # "revoked") now runs FIRST, before #deprovision!: the NFS branch of
      # #deprovision! calls NfsExportManager#revoke!, which — as of this
      # change — rebuilds the WHOLE exports file from live
      # StorageAssignment#active_credential rows (status "issued"/"active"
      # only, see that method). Rebuilding before this status flip would
      # still see this credential as active and re-include the very peer
      # this call exists to remove. Both statements share the SAME DB
      # transaction/connection as the caller (#rotate!'s #with_lock, or
      # StorageCredential#deprovision_before_destroy!'s SAVEPOINT) —
      # Postgres always sees its own uncommitted writes on that connection,
      # so ordering alone is correct here without needing an actual COMMIT
      # (contrast with the destroy path above, which needs a real commit
      # because what must be gone is the ROW itself, not just a status
      # column).
      #
      # TRANSACTION (review round — reordering credential.revoke! to run
      # FIRST reopened a gap the original ordering didn't have: the original
      # ran deprovision! then the provider revoke then credential.revoke!
      # LAST, so a raise anywhere earlier meant the status flip simply never
      # ran. With the flip moved first, a caller with no surrounding
      # transaction (this method is not always called from inside one — see
      # #rotate!'s #with_lock and StorageCredential's requires_new: true
      # SAVEPOINT for the two that ARE) would persist "revoked" even when
      # deprovision! then raised. Wrapping the whole body restores the
      # original all-or-nothing semantic while keeping the new ordering:
      # ActiveRecord::Base.transaction without requires_new: true joins an
      # existing transaction as a savepoint rather than opening a second
      # real one, so this is a no-op for the two callers already inside one.
      def revoke!(credential, successor: nil, defer_nfs_reconcile: false, skip_nfs_reconcile: false)
        ActiveRecord::Base.transaction do
          credential.revoke!

          deprovision!(credential, successor: successor, defer_nfs_reconcile: defer_nfs_reconcile,
                                    skip_nfs_reconcile: skip_nfs_reconcile)

          handle = credential.metadata["export_handle"] || credential.metadata["smb_user_handle"] || credential.metadata["sts_handle"]
          @storage.storage_provider.revoke_node_credential(handle) if handle
        end
      end

      private

      # "issued" (first-issuance not yet activated) and "active" (the normal
      # steady state #ensure_credential! rotates out of) are the only
      # statuses a rotation legitimately starts from. Anything else —
      # "rotating" (a concurrent caller is mid-flight, or genuinely
      # impossible once the lock above is in place since the whole rotation
      # is one transaction), "revoked"/"expired"/"failed" (someone already
      # rotated this row out) — means this call lost the race.
      def rotatable?(credential)
        %w[issued active].include?(credential.status)
      end

      # What a lost-race caller returns instead of a second new row: the
      # assignment's current active_credential (the winner's successor), or
      # the credential it was asked to rotate if, somehow, nothing is active
      # (defensive — should not happen once a winner has committed).
      def existing_successor_or(credential)
        @assignment.active_credential || credential
      end

      def issue_credential_row!
        raise IssuanceError, "Storage #{@assignment.file_storage_id} not found" unless @storage

        peer = ensure_peer!
        context = build_context(peer)

        provider_result = @storage.storage_provider.issue_node_credential(context: context)
        raise IssuanceError, "Provider returned nil credential" unless provider_result

        credential = ::System::StorageCredential.create!(
          storage_assignment: @assignment,
          node_instance_id: @assignment.node_instance_id,
          kind: provider_result[:kind],
          status: "issued",
          expires_at: provider_result[:ttl] ? provider_result[:ttl].from_now : nil,
          last_rotated_at: Time.current,
          metadata: (provider_result[:metadata] || {}).merge(peer_ip: peer&.assigned_address)
        )
        credential.store_in_vault(provider_result[:payload] || {})

        # Re-fetch (NOT reload) to bypass the @vault_credentials cache reload bug
        ::System::StorageCredential.find(credential.id)
      end

      def deprovision!(credential, successor:, defer_nfs_reconcile: false, skip_nfs_reconcile: false)
        case @storage.provider_type
        when "nfs"
          return if defer_nfs_reconcile || skip_nfs_reconcile

          NfsExportManager.new(assignment: @assignment).revoke!(credential: credential)
        when "smb"
          return if smb_username_superseded?(credential, successor)

          SmbUserManager.new(assignment: @assignment).deprovision_user!(credential: credential)
        end
      end

      # True exactly when some OTHER still-live credential on this
      # assignment (the explicit successor, if this came from #rotate!, or
      # any other issued/active/rotating row otherwise) names the SAME
      # samba-tool username as the one being revoked — i.e. deprovisioning
      # here would delete a user something else still needs. Checking every
      # live credential (not only an explicit successor) keeps a standalone
      # #revoke! call (no successor — e.g. retiring one of several rows)
      # correct too: it must still skip deprovision if a DIFFERENT live
      # credential already covers that username, and still deprovision when
      # this really is the last one.
      def smb_username_superseded?(credential, successor)
        username = credential.vault_credentials["username"]
        return false if username.blank?

        candidates = successor ? [ successor ] : other_live_credentials(credential)
        candidates.any? { |c| c.vault_credentials["username"] == username }
      end

      def other_live_credentials(credential)
        @assignment.storage_credentials
          .where(status: %w[issued active rotating])
          .where.not(id: credential.id)
      end

      def ensure_peer!
        return nil unless @assignment.sdwan_network_id

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

      def build_context(peer)
        {
          instance_id: @assignment.node_instance_id,
          instance_hostname: @assignment.node_instance&.name,
          peer_ip: peer&.assigned_address,
          uid: @assignment.anonuid,
          gid: @assignment.anongid,
          account_id: @assignment.account_id,
          sdwan_network_id: @assignment.sdwan_network_id,
          virtual_ip_address: @assignment.sdwan_virtual_ip&.cidr&.split("/")&.first,
          deployment_shape: @storage.deployment_shape,
          storage_configuration: @storage.configuration
        }
      end

      def materialize_backend_side!(credential)
        case @storage.provider_type
        when "nfs"
          NfsExportManager.new(assignment: @assignment).grant!(credential: credential)
        when "smb"
          SmbUserManager.new(assignment: @assignment).provision_user!(credential: credential)
        end
      end
    end
  end
end
