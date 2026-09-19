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
            rotate_smb_user!(credential: credential, new_credential: new_cred)
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

      # True exactly when some OTHER still-live credential names the SAME
      # samba-tool username as the one being revoked — i.e. deprovisioning
      # here would delete a user something else still needs. Checking every
      # live credential (not only an explicit successor) keeps a standalone
      # #revoke! call (no successor — e.g. retiring one of several rows)
      # correct too: it must still skip deprovision if a DIFFERENT live
      # credential already covers that username, and still deprovision when
      # this really is the last one.
      #
      # IMP-0376a1471f99 increment 1 — StorageProviders::SmbStorage
      # #issue_node_credential derives the samba-tool username
      # DETERMINISTICALLY from node_instance_id ALONE (see #rotate!'s own
      # comment above), so TWO DIFFERENT StorageAssignments for the SAME
      # node_instance (one node mounting two separate SMB shares) mint
      # credentials with the IDENTICAL username. #other_live_credentials
      # used to only look at OTHER credential rows on THIS SAME assignment
      # — it missed the sibling-assignment case entirely: revoking/
      # destroying one assignment's credential could still deprovision a
      # samba user a SIBLING assignment (different StorageAssignment row,
      # same node, same derived username) still needs.
      #
      # Widened to every live SMB credential, on ANY assignment in this
      # account, whose storage resolves to the SAME BACKEND node instance —
      # not just the same username. Same username on a DIFFERENT backend is
      # NOT a real collision (a different samba server has its own local
      # user namespace); deleting one there is correct and must still
      # proceed, which is why the backend check exists alongside the
      # username check rather than replacing it.
      #
      # FIXED by increment 3 (IMP-eb6a3c299f4b), for rotation specifically:
      # #rotate! now provisions the NEW username first and only revokes the
      # OLD one when the two differ (see #rotate_smb_user!) — that revoke
      # goes through this same method, so a same-backend sibling still on
      # the OLD username is still protected.
      #
      # `successor` is intentionally UNUSED here (increment 3 review) — it
      # used to short-circuit candidates to `[successor]` alone, which was
      # only ever correct because a rotation's successor PRE-increment-3
      # always shared the outgoing credential's username (so `[successor]`
      # trivially "superseded" it). Increment 2/3 make that false the
      # moment a rotation crosses from an old-scheme username to a new one:
      # the successor's username genuinely differs, so `[successor]` alone
      # would wrongly report "not superseded" even when some OTHER
      # same-backend sibling is still on the OLD username. Always
      # consulting #other_live_credentials fixes this — it is a super*set*
      # of `[successor]` already (a rotation's successor is itself a live,
      # same-account, same-backend credential the moment this runs, since
      # #rotate! commits new_cred.activate! before calling #revoke! — see
      # that method's own ordering comment — so it is always found by this
      # query on its own, without needing the shortcut).
      def smb_username_superseded?(credential, _successor)
        username = credential.vault_credentials["username"]
        return false if username.blank?

        other_live_credentials(credential).any? { |c| c.vault_credentials["username"] == username }
      end

      def other_live_credentials(credential)
        backend_id = smb_backend_node_instance_id(@storage)

        # #smb_same_backend? below reads c.storage_assignment for every row
        # this scope returns — .includes avoids an N+1 SELECT per candidate
        # credential (file_storage itself is a hand-written lookup, not a
        # declared association, so it can't be chained into the same
        # .includes; only the storage_assignment join is eager-loadable).
        ::System::StorageCredential
          .includes(:storage_assignment)
          .joins(:storage_assignment)
          .merge(::System::StorageAssignment.where(account_id: @assignment.account_id))
          .where(status: %w[issued active rotating])
          .where.not(id: credential.id)
          .select { |c| smb_same_backend?(c, backend_id) }
      end

      # backend_id nil (no backend configured at all — shouldn't happen for
      # a live SMB storage, defensive) never matches anything, rather than
      # every other backend-less storage matching each other.
      def smb_same_backend?(other_credential, backend_id)
        return false unless backend_id

        other_storage = other_credential.storage_assignment&.file_storage
        other_storage&.smb? && smb_backend_node_instance_id(other_storage) == backend_id
      end

      # Mirrors SmbUserManager#backend_node_instance_id EXACTLY (also
      # duplicated, unchanged, in NfsExportManager) — reused, not
      # reinvented, per the operator's explicit direction for this
      # increment.
      def smb_backend_node_instance_id(storage)
        return nil unless storage

        if storage.gateway_proxy?
          storage.configuration["gateway_node_instance_id"]
        else
          storage.configuration["export_host_node_instance_id"]
        end
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

      # IMP-eb6a3c299f4b increment 3 — StorageProviders::SmbStorage
      # #issue_node_credential (increment 2) now derives the samba-tool
      # username per-(instance, storage) instead of per-instance-alone, so
      # an OLD-scheme credential (issued before that change, still on its
      # original 90-day TTL — NOT force-migrated, see below) and its
      # rotated successor can end up with DIFFERENT usernames.
      # #rotate_user! (agent: setSambaPassword) only ever changes an
      # EXISTING user's password — it cannot rename one — so a scheme
      # switch must PROVISION the new username (action "create") instead.
      #
      # The OLD username's delete still happens, unchanged, via #rotate!'s
      # own subsequent #revoke!(credential, successor: new_cred, ...) call
      # — #smb_username_superseded? (the increment-1 same-backend guard,
      # now always consulted — see that method's own comment) still decides
      # whether some OTHER same-backend sibling still needs the old
      # username before deleting it. This method does not need to (and
      # must not) dispatch that delete itself.
      #
      # Same-username rotations — the common case until every credential
      # has naturally rotated onto the new scheme — still use the cheaper
      # single set_password dispatch, unchanged.
      #
      # NOT a forced migration: an old-scheme credential is left exactly
      # alone until ITS OWN next scheduled rotation (#ensure_credential!'s
      # expiry?/needs_rotation? check, untouched by this change) decides to
      # rotate it — no sweep is dispatched here or anywhere else.
      def rotate_smb_user!(credential:, new_credential:)
        old_username = credential.vault_credentials["username"]
        new_username = new_credential.vault_credentials["username"]

        if old_username == new_username
          SmbUserManager.new(assignment: @assignment).rotate_user!(credential: credential, new_credential: new_credential)
        else
          SmbUserManager.new(assignment: @assignment).provision_user!(credential: new_credential)
        end
      end
    end
  end
end
