# frozen_string_literal: true

module System
  class StorageCredential < BaseRecord
    include System::Base
    include ::VaultCredential

    self.vault_credential_type = "storage_node_access"

    KINDS = %w[peer_ip_acl cifs_user_pass sts_token tls_cert webdav_basic].freeze
    STATUSES = %w[issued active rotating revoked expired failed].freeze

    belongs_to :storage_assignment, class_name: "System::StorageAssignment"
    belongs_to :node_instance, class_name: "::System::NodeInstance"

    delegate :account, to: :storage_assignment
    delegate :account_id, to: :storage_assignment

    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: STATUSES }

    # IMP-e88b38770d13 — StorageAssignment's own `dependent: :destroy` (and
    # System::NodeInstance::CASCADE_DEPENDENTS, which destroys both
    # StorageAssignment and StorageCredential rows for a node) used to just
    # delete the row: no samba-tool deprovision, no NFS peer ACL revoke, no
    # provider-side revoke_node_credential. The backend kept working
    # credentials for a node/assignment the platform believes no longer
    # exists.
    #
    # This is the choke point every destroy path converges on —
    # StorageAssignment#destroy, NodeInstance#destroy (now that NodeInstance
    # declares `has_many :storage_assignments/:storage_credentials,
    # dependent: :destroy` itself — review round 1; both FKs are ON DELETE
    # CASCADE at the DB level and were previously undeclared at the AR
    # level, so a PLAIN instance.destroy let Postgres cascade these away
    # with zero callbacks), NodeInstance#cascade_destroy_dependents!'s
    # force=true path, AND — also review round 1 — Ai::Tools::SystemFleetTool
    # #destroy_instance: its DESTROY_INSTANCE_FKS raw-SQL cascade used to
    # delete system_storage_credentials directly, bypassing this hook
    # entirely; that table (and system_storage_assignments) was removed from
    # DESTROY_INSTANCE_FKS specifically so that method's own `instance
    # .destroy!` reaches this same hook through the new has_many, instead of
    # every raw-SQL caller needing its own hand-written equivalent.
    # `prepend: true` puts this BEFORE the association's own
    # dependent: :destroy callback in the chain, so it runs while the row
    # (and its storage_assignment) still exists.
    #
    # Multiple LIVE siblings sharing the same SMB username (e.g. a rotation
    # mid-flight when the assignment is torn down) are still handled
    # correctly: Rails destroys has_many dependents one full cycle at a
    # time, so by the time the LAST live one's callback runs, every earlier
    # sibling has already been fully deleted from the DB — CredentialIssuer
    # #revoke!'s existing "any OTHER live credential with this username"
    # check (smb_username_superseded?, no explicit successor) then correctly
    # sees none, and THAT call is the one that actually deprovisions.
    # Earlier siblings correctly no-op (they see a still-live twin) but are
    # still marked revoked before their own row disappears.
    #
    # Best-effort: an exception raised inside a before_destroy callback
    # aborts the whole destroy (and the surrounding transaction) — a
    # deprovision failure (backend unreachable, storage already gone) must
    # never make an otherwise-valid destroy impossible. Matches the same
    # rescue-and-log pattern StorageAssignment's own trigger_reconcile /
    # dispatch_chown_if_pending callbacks use.
    before_destroy :deprovision_before_destroy!, prepend: true

    # Review round 1 — NFS's exports file cannot be revoked one credential at
    # a time (see #deprovision_before_destroy!'s defer_nfs_reconcile note);
    # it needs a full rebuild from live DB state, and that rebuild is only
    # correct once this row (and possibly its storage_assignment) is
    # actually gone. after_destroy_commit runs after the surrounding
    # transaction has truly committed — including the outer transaction of
    # a StorageAssignment#destroy or NodeInstance#destroy this row cascaded
    # from — which both guarantees the row is gone and, as a side effect,
    # means this never competes for @storage's advisory lock with anything
    # still holding a lock from the destroy itself.
    after_destroy_commit :reconcile_nfs_exports_after_destroy!

    scope :active, -> { where(status: %w[issued active]) }
    scope :rotating, -> { where(status: "rotating") }
    scope :expired_or_failed, -> { where(status: %w[expired failed revoked]) }

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    def needs_rotation?(window: 1.day)
      expires_at.present? && expires_at <= window.from_now
    end

    def activate!
      update!(status: "active")
    end

    def mark_rotating!
      update!(status: "rotating")
    end

    def revoke!
      update!(status: "revoked")
    end

    private

    # Skips cleanly for a credential that never needed deprovisioning
    # (already revoked/expired/failed) or whose storage backend is already
    # gone (defensive — CredentialIssuer#initialize memoizes
    # assignment.file_storage, which is a hand-written account-scoped
    # lookup, not an FK, so it can legitimately resolve nil).
    #
    # defer_nfs_reconcile: true for an NFS-backed credential — skips the
    # dispatch inside CredentialIssuer#revoke! entirely and instead stashes
    # @storage for #reconcile_nfs_exports_after_destroy! to rebuild the full
    # file once this row is gone. NfsExportManager#revoke! (as of
    # IMP-ba7956c5b38d) already does a full rebuild from live
    # StorageAssignment#active_credential rows rather than a single-entry
    # dispatch, but that rebuild is only correct once THIS row — and, for a
    # whole-assignment/instance teardown, its storage_assignment too — is
    # actually gone from the DB: calling it from inside this before_destroy
    # hook, before the row is deleted, would still see this credential (or a
    # sibling mid-cascade) as live and wrongly re-include it. Deferring to
    # after_destroy_commit is what guarantees the row is truly gone, and the
    # whole destroy transaction has committed, before the rebuild runs.
    #
    # requires_new: true opens a SAVEPOINT rather than joining the caller's
    # destroy transaction. Without it, a DB-level error inside revoke! — a
    # lock timeout, or a genuine deadlock between #rotate! (row lock then
    # NFS's advisory lock) and this hook — would mark the WHOLE surrounding
    # transaction aborted; every later statement in it, including the
    # DELETE this callback exists to let through, would then fail with
    # "current transaction is aborted, commands ignored until end of
    # transaction block", and the rescue below would never get a chance to
    # keep the destroy alive. A savepoint rollback is scoped to just this
    # block, leaving the outer destroy transaction usable.
    def deprovision_before_destroy!
      assignment = storage_assignment
      storage = assignment&.file_storage

      # IMP-e48612a32273 (review correction) — teardown-mid-rotation: a
      # scheme-crossing rotation's outgoing credential now stays "rotating"
      # (not "revoked") until the consumer's remount confirms — see
      # CredentialIssuer#revoke!'s own comment for why. That means THIS
      # pre-existing guard (issued/active/rotating) already covers a
      # "rotating" credential whose assignment is destroyed before that
      # confirmation ever arrives: it falls straight through to the normal
      # #revoke! call below, exactly like any other live credential being
      # torn down, with no special case needed. (An earlier version of this
      # method added a breadcrumb-specific pre-check here; the breadcrumb
      # design was replaced by the state-derived "rotating" approach, which
      # made that pre-check unnecessary.)
      return unless %w[issued active rotating].include?(status)
      return unless storage

      nfs_teardown = storage.nfs?
      @nfs_storage_pending_reconcile = storage if nfs_teardown

      ActiveRecord::Base.transaction(requires_new: true) do
        ::System::Storage::CredentialIssuer.new(assignment: assignment)
          .revoke!(self, defer_nfs_reconcile: nfs_teardown)
      end
    rescue StandardError => e
      Rails.logger.error("[StorageCredential##{id}] deprovision-on-destroy failed: #{e.class}: #{e.message}")
    end

    # Full-file rebuild, deferred here (rather than dispatched synchronously
    # from #deprovision_before_destroy!) because it must run once this row —
    # and, in a whole-assignment teardown, the storage_assignment itself —
    # is truly gone from the DB: NfsExportManager.reconcile! reads live
    # StorageAssignment/#active_credential rows, so running it any earlier
    # would still see this credential (or a sibling mid-destroy) as live and
    # wrongly include it.
    def reconcile_nfs_exports_after_destroy!
      storage = @nfs_storage_pending_reconcile
      return unless storage

      ::System::Storage::NfsExportManager.reconcile!(storage: storage)
    rescue StandardError => e
      Rails.logger.error("[StorageCredential##{id}] NFS exports reconcile-on-destroy failed: #{e.class}: #{e.message}")
    end
  end
end
