# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Storage::CredentialIssuer do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:node_instance) do
    instance = create(:system_node_instance, account: account)
    # PeerEnroller stamps a /128 on save, which the issuer reads as peer_ip.
    Sdwan::PeerEnroller.call(network: network, node_instance: instance)
    instance
  end
  let(:file_storage) do
    create(:file_storage, :nfs, :node_mountable, account: account,
      configuration: {
        "export_path" => "/srv/exports/test",
        "mount_path" => "/srv/exports/test",
        "share_path" => "/srv/exports/test",
        "server_address" => "127.0.0.1",
        "export_host_node_instance_id" => create(:system_node_instance, account: account).id
      })
  end
  let(:assignment) do
    create(:system_storage_assignment,
      account: account,
      file_storage_id: file_storage.id,
      node_instance: node_instance,
      sdwan_network: network,
      mount_path: "/mnt/test")
  end

  subject(:issuer) { described_class.new(assignment: assignment) }

  def smb_tasks_for(assignment)
    System::Task.where(command: "storage.smb_user.apply", account_id: assignment.account_id).order(:created_at)
  end

  describe "#issue!" do
    it "creates a StorageCredential with peer_ip_acl kind for NFS" do
      credential = issuer.issue!
      expect(credential).to be_a(System::StorageCredential)
      expect(credential.kind).to eq("peer_ip_acl")
      expect(credential.status).to eq("active")
    end

    it "records peer_ip in the credential metadata" do
      credential = issuer.issue!
      expect(credential.metadata["peer_ip"]).to be_present
    end

    it "dispatches a storage.exports.apply task to the backend peer" do
      # The assignment's after_commit reconciler may have already fired one
      # exports task during setup; we just assert that an explicit issue! call
      # produces at least one more.
      before_count = System::Task.where(command: "storage.exports.apply").count
      issuer.issue!
      expect(System::Task.where(command: "storage.exports.apply").count).to be > before_count
    end

    it "raises if the storage is missing" do
      assignment.update_columns(file_storage_id: SecureRandom.uuid)
      assignment.instance_variable_set(:@file_storage, nil)
      expect { issuer.issue! }.to raise_error(described_class::IssuanceError)
    end
  end

  describe "#revoke!" do
    it "marks the credential revoked" do
      credential = issuer.issue!
      issuer.revoke!(credential)
      expect(credential.reload.status).to eq("revoked")
    end

    # IMP-ba7956c5b38d review round — reordering credential.revoke! to run
    # BEFORE deprovision! (needed so the NFS rebuild excludes the peer being
    # revoked) reopened a gap the original "deprovision, then revoke last"
    # ordering never had: without a transaction wrapping the whole method, a
    # caller with no surrounding transaction of its own would persist the
    # status flip even when deprovision! then raised. Calling #revoke!
    # directly here, with no enclosing transaction, is exactly that case.
    it "rolls back the status flip when deprovision fails, with no surrounding transaction" do
      credential = issuer.issue!
      allow_any_instance_of(System::Storage::NfsExportManager)
        .to receive(:revoke!).and_raise(StandardError, "backend unreachable")

      expect { issuer.revoke!(credential) }.to raise_error(StandardError, "backend unreachable")
      expect(credential.reload.status).to eq("active")
    end
  end

  # IMP-9045875d3cb8 — CredentialIssuer#rotate! called #issue! (dispatching a
  # "create" for the new credential) then #revoke!(old) (dispatching a
  # "delete" for the OLD credential's samba-tool user). StorageProviders::
  # SmbStorage#issue_node_credential derives the username deterministically
  # from node_instance_id, so old and new always share the same username —
  # every rotation deleted the SMB user it had just re-created/re-passworded.
  describe "#rotate!" do
    context "for NFS (non-SMB storage stays unchanged)" do
      it "grants the new credential and revokes the old one exactly as before" do
        credential = issuer.issue!
        before_count = System::Task.where(command: "storage.exports.apply").count

        new_cred = issuer.rotate!(credential)

        expect(new_cred).to be_a(System::StorageCredential)
        expect(new_cred.status).to eq("active")
        expect(credential.reload.status).to eq("revoked")
        expect(System::Task.where(command: "storage.exports.apply").count).to be > before_count
        expect(System::Task.where(command: "storage.smb_user.apply")).to be_empty
      end

      # IMP-ba7956c5b38d — #grant!/#revoke! now do a FULL exports-file
      # rebuild (System::Storage::NfsExportManager#reconcile!) instead of a
      # single-entry dispatch. A storage with only ONE client can't catch a
      # regression back to single-entry dispatch (both look identical with
      # one entry) — this uses a SECOND, unrelated client on the same
      # storage to prove the rebuild is genuinely storage-wide.
      it "keeps a surviving OTHER client exported across rotation, dispatching exactly one exports.apply task" do
        # assignment's own after_commit auto-issues a credential sharing the
        # SAME underlying Sdwan::Peer (and therefore the same peer_ip) this
        # test's explicit #issue! call below also resolves — clear it first
        # or a stale, still-"active" sibling with an IDENTICAL peer_ip would
        # make the "excluded" assertion below pass or fail for the wrong
        # reason regardless of this task's actual fix.
        assignment.storage_credentials.update_all(status: "revoked")
        credential = issuer.issue!

        other_instance = create(:system_node_instance, account: account)
        ::Sdwan::PeerEnroller.call(network: network, node_instance: other_instance)
        other_assignment = create(:system_storage_assignment,
          account: account, file_storage_id: file_storage.id, node_instance: other_instance,
          sdwan_network: network, mount_path: "/mnt/other")
        # See the top-level SMB fixtures' own comment: StorageAssignment's
        # after_commit auto-issues a credential the moment the row is
        # created — clear it so the explicit #issue! below is the only
        # live credential for this second assignment.
        other_assignment.storage_credentials.update_all(status: "revoked")
        other_credential = described_class.new(assignment: other_assignment).issue!

        before_ids = System::Task.where(command: "storage.exports.apply").pluck(:id)
        new_cred = issuer.rotate!(credential)

        # ONE dispatch, not two (see #rotate!'s own comment: the #grant!
        # dispatch for new_cred already rebuilds the whole file correctly —
        # a second one from #revoke!(credential) would be redundant).
        new_tasks = System::Task.where(command: "storage.exports.apply").where.not(id: before_ids)
        expect(new_tasks.count).to eq(1)

        # NOT a not_to-include(credential.metadata["peer_ip"]) check: rotation
        # replaces the credential ROW but resolves the SAME Sdwan::Peer for
        # the same (node_instance_id, sdwan_network_id) — new_cred's peer_ip
        # is therefore IDENTICAL to the old credential's, by construction
        # (CredentialIssuer#ensure_peer! reuses an existing peer). Entries
        # are built one per LIVE ASSIGNMENT (StorageAssignment#active_credential),
        # not one per credential row, so what this fix actually guarantees is
        # exactly one entry per live assignment — no duplicate/stale row left
        # over from the old, now-revoked credential.
        entries = new_tasks.first.options["entries"]
        expect(entries.size).to eq(2)
        peer_ips = entries.map { |e| e["peer_ip"] }
        expect(peer_ips).to contain_exactly(new_cred.metadata["peer_ip"], other_credential.metadata["peer_ip"])
      end
    end

    context "for SMB" do
      let(:backend_instance) { create(:system_node_instance, account: account) }
      let(:smb_storage) do
        create(:file_storage, :smb, :node_mountable, account: account,
          configuration: {
            "mount_path" => "/mnt/smb-test",
            "server_address" => "192.168.1.200",
            "share_name" => "storage",
            "export_host_node_instance_id" => backend_instance.id
          })
      end
      let(:smb_assignment) do
        create(:system_storage_assignment,
          account: account, file_storage_id: smb_storage.id,
          node_instance: node_instance, mount_path: "/mnt/smb-test")
      end
      subject(:smb_issuer) { described_class.new(assignment: smb_assignment) }

      def smb_tasks
        System::Task.where(command: "storage.smb_user.apply").order(:created_at)
      end

      it "dispatches exactly one set_password task naming both credentials — never a delete" do
        credential = smb_issuer.issue!
        before_ids = smb_tasks.pluck(:id)

        new_cred = smb_issuer.rotate!(credential)

        new_tasks = smb_tasks.where.not(id: before_ids)
        expect(new_tasks.count).to eq(1)
        task = new_tasks.first
        expect(task.options["action"]).to eq("set_password")
        expect(task.options["credential"]["id"]).to eq(credential.id)
        expect(task.options["new_credential"]["id"]).to eq(new_cred.id)
        expect(smb_tasks.where("options ->> 'action' = 'delete'")).to be_empty
      end

      it "keeps the same deterministic samba-tool username but a genuinely new password" do
        credential = smb_issuer.issue!
        old_username = credential.vault_credentials["username"]
        old_password = credential.vault_credentials["password"]

        new_cred = smb_issuer.rotate!(credential)

        expect(new_cred.vault_credentials["username"]).to eq(old_username)
        expect(new_cred.vault_credentials["password"]).not_to eq(old_password)
      end

      it "revokes the old credential row (DB status) once rotation has dispatched" do
        credential = smb_issuer.issue!
        smb_issuer.rotate!(credential)
        expect(credential.reload.status).to eq("revoked")
      end
    end
  end

  # IMP-026b8017d0b0 — two callers (the operator's rotate_credential action,
  # AssignmentReconciliationService#ensure_credential! on a heartbeat/drift
  # tick, or any future one) can both resolve the SAME active_credential
  # before either has written anything, and both used to issue an
  # independent new row + dispatch — samba ends up with whichever task's
  # password the agent applied last, while active_credential serves
  # whichever row committed last, and the two can disagree.
  #
  # This tests the STATUS RE-CHECK #rotate!'s row lock gates, not the LOCK'S
  # BLOCKING behavior itself: a same-connection thread/lock probe proves
  # nothing under RSpec's transactional fixtures (a single pinned connection
  # sees its own row locks as re-entrant — the same reason a session
  # advisory-lock self-probe is worthless), and matches this file's own
  # existing "storage.unmount dispatch dedupe" spec's approach — two
  # SEPARATELY LOADED references to the same row, both loaded BEFORE either
  # caller has written anything, called sequentially.
  #
  # The separate load matters for what this actually proves: `stale` is
  # fetched before the first #rotate! runs, so its OWN in-memory `status`
  # attribute still reads "active"/"issued" at the moment it is handed to
  # the second #rotate! call — exactly what a second real caller's copy
  # would look like. A version of #rotate! that checked rotatable?(credential)
  # from that cached attribute — e.g. outside #with_lock, before the reload
  # — would see "active" and wrongly proceed to mint a third row. Only a
  # version that RELOADS under the lock (#with_lock's #lock! does this) sees
  # what the first call actually left behind. Passing the SAME object twice
  # would not distinguish these two implementations, because that object's
  # own `status` attribute gets mutated in-memory by the first call whether
  # or not anything reloads under a lock.
  describe "#rotate! concurrency (row lock + status re-check)" do
    it "for NFS: a second rotate! call on a stale, separately-loaded reference to the same row returns the winner's successor, not a third row" do
      credential = issuer.issue!
      stale = System::StorageCredential.find(credential.id)

      first_new = issuer.rotate!(credential)
      before_task_count = System::Task.where(command: "storage.exports.apply").count
      before_credential_count = System::StorageCredential.where(storage_assignment: assignment).count

      second_result = issuer.rotate!(stale)

      expect(second_result.id).to eq(first_new.id)
      expect(System::StorageCredential.where(storage_assignment: assignment).count).to eq(before_credential_count)
      expect(System::Task.where(command: "storage.exports.apply").count).to eq(before_task_count)
    end

    context "for SMB" do
      let(:backend_instance) { create(:system_node_instance, account: account) }
      let(:smb_storage) do
        create(:file_storage, :smb, :node_mountable, account: account,
          configuration: {
            "mount_path" => "/mnt/smb-race",
            "server_address" => "192.168.1.203",
            "share_name" => "storage-race",
            "export_host_node_instance_id" => backend_instance.id
          })
      end
      let(:smb_assignment) do
        create(:system_storage_assignment,
          account: account, file_storage_id: smb_storage.id,
          node_instance: node_instance, mount_path: "/mnt/smb-race")
      end
      subject(:smb_issuer) { described_class.new(assignment: smb_assignment) }

      def smb_tasks
        System::Task.where(command: "storage.smb_user.apply").order(:created_at)
      end

      it "a double rotate! on a stale, separately-loaded reference to the same active credential yields exactly one new row and one set_password dispatch" do
        # StorageAssignment#after_commit auto-issues its OWN credential for
        # this same deterministic username on create — revoke it first so
        # the count assertions below are about THIS test's rotation, not
        # that auto-issued sibling (same gotcha the SMB rotation-fix task
        # hit; see credential_issuer_spec's other "revoke!" describe block).
        smb_assignment.storage_credentials.update_all(status: "revoked")

        credential = smb_issuer.issue!
        stale = System::StorageCredential.find(credential.id)
        before_ids = smb_tasks.pluck(:id)

        first_new = smb_issuer.rotate!(credential)
        second_result = smb_issuer.rotate!(stale)

        expect(second_result.id).to eq(first_new.id)
        expect(System::StorageCredential.where(storage_assignment: smb_assignment, status: %w[issued active]).count).to eq(1)
        new_tasks = smb_tasks.where.not(id: before_ids)
        expect(new_tasks.count).to eq(1)
        expect(new_tasks.first.options["action"]).to eq("set_password")
      end
    end
  end

  # The "true removal" case #rotate! deliberately does NOT exercise: no
  # successor exists, so #revoke! must still deprovision — this is the case
  # the username-collision guard must never swallow.
  describe "#revoke! (true removal, no successor)" do
    # IMP-ba7956c5b38d — proves the ORDERING fix directly: #revoke! now
    # flips credential.status to "revoked" BEFORE calling into
    # NfsExportManager#revoke! (which rebuilds the whole exports file from
    # live StorageAssignment#active_credential rows, status
    # issued/active only). Rebuilding before that status flip would still
    # see this credential as active and re-include the very peer this
    # call exists to remove — a storage with only ONE client can't catch
    # that regression (it would just look like the file being removed
    # instead of overwritten either way), hence the second client here.
    it "for NFS: excludes the revoked peer while keeping a second client exported" do
      # Same auto-issued-sibling fixture gotcha as the rotation test above —
      # clear it before the explicit #issue! or a stale, still-"active"
      # sibling with the SAME peer_ip masks whether the revoke actually
      # excluded this credential's own peer.
      assignment.storage_credentials.update_all(status: "revoked")
      credential = issuer.issue!

      other_instance = create(:system_node_instance, account: account)
      ::Sdwan::PeerEnroller.call(network: network, node_instance: other_instance)
      other_assignment = create(:system_storage_assignment,
        account: account, file_storage_id: file_storage.id, node_instance: other_instance,
        sdwan_network: network, mount_path: "/mnt/other-revoke")
      other_assignment.storage_credentials.update_all(status: "revoked")
      other_credential = described_class.new(assignment: other_assignment).issue!

      before_ids = System::Task.where(command: "storage.exports.apply").pluck(:id)
      issuer.revoke!(credential)

      new_tasks = System::Task.where(command: "storage.exports.apply").where.not(id: before_ids)
      peer_ips = new_tasks.last.options["entries"].map { |e| e["peer_ip"] }
      expect(peer_ips).not_to include(credential.metadata["peer_ip"])
      expect(peer_ips).to include(other_credential.metadata["peer_ip"])
      expect(credential.reload.status).to eq("revoked")
    end

    it "still deprovisions the SMB user when it is the last live credential for that username" do
      backend_instance = create(:system_node_instance, account: account)
      smb_storage = create(:file_storage, :smb, :node_mountable, account: account,
        configuration: {
          "mount_path" => "/mnt/smb-test2",
          "server_address" => "192.168.1.201",
          "share_name" => "storage2",
          "export_host_node_instance_id" => backend_instance.id
        })
      smb_assignment = create(:system_storage_assignment,
        account: account, file_storage_id: smb_storage.id,
        node_instance: node_instance, mount_path: "/mnt/smb-test2")
      smb_issuer = described_class.new(assignment: smb_assignment)

      # StorageAssignment#after_commit auto-triggers reconciliation on
      # create, which (since nothing was live yet) issues its OWN
      # credential for the same deterministic username — revoke that one
      # first so the credential under test is genuinely the LAST live one,
      # not superseded by an auto-issued sibling neither #issue! nor this
      # example asked for.
      smb_assignment.storage_credentials.update_all(status: "revoked")

      credential = smb_issuer.issue!
      smb_issuer.revoke!(credential)

      delete_task = System::Task.where(command: "storage.smb_user.apply")
        .where("options ->> 'action' = 'delete'").order(:created_at).last
      expect(delete_task).to be_present
      expect(delete_task.options["credential"]["id"]).to eq(credential.id)
      expect(credential.reload.status).to eq("revoked")
    end

    it "still skips deprovision when a DIFFERENT live credential already covers the same username (no explicit successor)" do
      backend_instance = create(:system_node_instance, account: account)
      smb_storage = create(:file_storage, :smb, :node_mountable, account: account,
        configuration: {
          "mount_path" => "/mnt/smb-test3",
          "server_address" => "192.168.1.202",
          "share_name" => "storage3",
          "export_host_node_instance_id" => backend_instance.id
        })
      smb_assignment = create(:system_storage_assignment,
        account: account, file_storage_id: smb_storage.id,
        node_instance: node_instance, mount_path: "/mnt/smb-test3")
      smb_issuer = described_class.new(assignment: smb_assignment)

      first = smb_issuer.issue!
      # A second credential for the SAME deterministic username, issued
      # independently (not via #rotate!, so #revoke! below gets no explicit
      # successor) — #other_live_credentials must still find it.
      second = smb_issuer.send(:issue_credential_row!)
      second.activate!

      before_ids = smb_tasks_for(smb_assignment).pluck(:id)
      smb_issuer.revoke!(first)

      new_tasks = smb_tasks_for(smb_assignment).where.not(id: before_ids)
      expect(new_tasks).to be_empty
      expect(first.reload.status).to eq("revoked")
    end
  end

  # IMP-0376a1471f99 increment 1 — StorageProviders::SmbStorage
  # #issue_node_credential derives the samba-tool username DETERMINISTICALLY
  # from node_instance_id alone: two DIFFERENT StorageAssignments for the
  # SAME node_instance (one node mounting two separate SMB shares) mint
  # credentials with the IDENTICAL username. The pre-increment-1
  # #other_live_credentials only looked at credentials on THIS SAME
  # assignment — it missed the cross-assignment case entirely, so revoking
  # one assignment's credential could delete a samba user a SIBLING
  # assignment still needed.
  # IMP-0376a1471f99 increment 1 / IMP-eb6a3c299f4b increments 2+3 —
  # increment 2 makes the samba-tool username derivation per-(instance,
  # storage) instead of per-instance-alone, so two REAL, freshly-issued
  # credentials on different storages no longer share a username by
  # construction (a genuine SHA256 collision is not something a test
  # should rely on). These specs exist to prove the CROSS-ASSIGNMENT
  # COLLISION GUARD's own logic, so they force a shared username onto two
  # otherwise-normal credentials explicitly — standing in for the LEGACY
  # state increment 2 exists to eventually retire (an old-scheme credential
  # that has not yet hit its own next rotation).
  describe "SMB cross-assignment username collision" do
    let(:backend_instance) { create(:system_node_instance, account: account) }
    let(:other_backend_instance) { create(:system_node_instance, account: account) }

    before do
      # vault_credentials stubbed to mirror metadata so the forced,
      # shared username below can be controlled purely through the
      # metadata column, without touching real Vault.
      allow_any_instance_of(System::StorageCredential)
        .to receive(:vault_credentials) { |instance| instance.metadata.slice("username") }
    end

    def smb_storage_for(backend_id, share:)
      create(:file_storage, :smb, :node_mountable, account: account,
        configuration: {
          "mount_path" => "/mnt/#{share}", "server_address" => "192.168.1.210",
          "share_name" => share, "export_host_node_instance_id" => backend_id
        })
    end

    def build_assignment_and_credential(storage, mount_path:, username: nil)
      assignment = create(:system_storage_assignment,
        account: account, file_storage_id: storage.id, node_instance: node_instance, mount_path: mount_path)
      # StorageAssignment#after_commit auto-issues its OWN credential —
      # clear it so the explicit #issue! below is the only live credential
      # for this assignment.
      assignment.storage_credentials.update_all(status: "revoked")
      credential = described_class.new(assignment: assignment).issue!
      credential.update_columns(metadata: credential.metadata.merge("username" => username)) if username
      [ assignment, credential ]
    end

    def smb_tasks
      System::Task.where(command: "storage.smb_user.apply").order(:created_at)
    end

    it "dispatches NO delete when a sibling assignment on the SAME backend still uses the same username" do
      storage_a = smb_storage_for(backend_instance.id, share: "share-a")
      storage_b = smb_storage_for(backend_instance.id, share: "share-b")
      shared_username = "n-legacyshared0001"
      assignment_a, credential_a = build_assignment_and_credential(storage_a, mount_path: "/mnt/share-a", username: shared_username)
      _assignment_b, credential_b = build_assignment_and_credential(storage_b, mount_path: "/mnt/share-b", username: shared_username)

      before_ids = smb_tasks.pluck(:id)
      described_class.new(assignment: assignment_a).revoke!(credential_a)

      expect(smb_tasks.where.not(id: before_ids).where("options ->> 'action' = 'delete'")).to be_empty
      expect(credential_a.reload.status).to eq("revoked")
      expect(credential_b.reload.status).to eq("active") # untouched — the sibling's samba user must survive
    end

    it "DOES dispatch a delete when the sibling assignment's storage has a DIFFERENT backend" do
      storage_a = smb_storage_for(backend_instance.id, share: "share-c")
      storage_b = smb_storage_for(other_backend_instance.id, share: "share-d")
      shared_username = "n-legacyshared0002"
      assignment_a, credential_a = build_assignment_and_credential(storage_a, mount_path: "/mnt/share-c", username: shared_username)
      _assignment_b, credential_b = build_assignment_and_credential(storage_b, mount_path: "/mnt/share-d", username: shared_username)

      before_ids = smb_tasks.pluck(:id)
      described_class.new(assignment: assignment_a).revoke!(credential_a)

      delete_task = smb_tasks.where.not(id: before_ids).where("options ->> 'action' = 'delete'").last
      expect(delete_task).to be_present
      expect(delete_task.options["credential"]["id"]).to eq(credential_a.id)
    end

    # FLIPPED for IMP-eb6a3c299f4b increment 3 — this used to prove
    # rotation was NOT protected (increment 1 only gated the delete path,
    # never set_password). Increment 3 fixes exactly this: a rotation whose
    # new username differs from the old one now PROVISIONS the new
    # username instead of running set_password against the shared OLD one,
    # so the sibling still on that old username is never touched.
    it "rotating an old-scheme credential provisions the new username and leaves the sibling's password untouched" do
      storage_a = smb_storage_for(backend_instance.id, share: "share-e")
      storage_b = smb_storage_for(backend_instance.id, share: "share-f")
      shared_username = "n-legacyshared0003"
      assignment_a, credential_a = build_assignment_and_credential(storage_a, mount_path: "/mnt/share-e", username: shared_username)
      _assignment_b, credential_b = build_assignment_and_credential(storage_b, mount_path: "/mnt/share-f", username: shared_username)

      before_ids = smb_tasks.pluck(:id)
      new_cred = described_class.new(assignment: assignment_a).rotate!(credential_a)

      # A "create" for the NEW (real, un-forced, genuinely distinct)
      # username — never a "set_password" naming the shared old one.
      expect(smb_tasks.where.not(id: before_ids).where("options ->> 'action' = 'set_password'")).to be_empty
      create_task = smb_tasks.where.not(id: before_ids).where("options ->> 'action' = 'create'").last
      expect(create_task).to be_present
      expect(create_task.options["username"]).to eq(new_cred.vault_credentials["username"])
      expect(create_task.options["username"]).not_to eq(shared_username)

      expect(credential_b.reload.status).to eq("active") # sibling's password never touched
    end

    # The delete of the OLD username still happens once nothing else needs
    # it — unchanged from increment 1, just now reached via #rotate! taking
    # the provision-then-revoke path instead of set_password.
    it "still deletes the old username after rotation once no sibling needs it" do
      storage_a = smb_storage_for(backend_instance.id, share: "share-g")
      shared_username = "n-legacyshared0004"
      assignment_a, credential_a = build_assignment_and_credential(storage_a, mount_path: "/mnt/share-g", username: shared_username)

      before_ids = smb_tasks.pluck(:id)
      described_class.new(assignment: assignment_a).rotate!(credential_a)

      delete_task = smb_tasks.where.not(id: before_ids).where("options ->> 'action' = 'delete'").last
      expect(delete_task).to be_present
      expect(delete_task.options["credential"]["id"]).to eq(credential_a.id)
      expect(credential_a.reload.status).to eq("revoked")
    end
  end
end
