# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Storage::AssignmentReconciliationService do
  let(:account) { create(:account) }
  let(:node_instance) { create(:system_node_instance, account: account) }
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
      mount_path: "/mnt/test")
  end

  describe "backoff escalation on repeated failures" do
    before do
      # Force every reconcile attempt to fail past the peer step so the
      # attempt/backoff bookkeeping in error_message can be observed in
      # isolation from the happy path.
      allow(System::Storage::CredentialIssuer).to receive(:new).and_raise(StandardError, "boom")
    end

    it "grows the backoff delay on the second failure instead of pinning it at BACKOFF_BASE" do
      assignment # materialize — the after_commit trigger fires the first (failing) reconcile
      assignment.reload
      expect(assignment.error_message).to match(/attempt:1 backoff_until:/)

      # Expire the stored backoff so a second trigger actually re-attempts the
      # work rather than short-circuiting on in_backoff?.
      assignment.update_columns(
        error_message: assignment.error_message.sub(/backoff_until:\S+/, "backoff_until:#{1.second.ago.iso8601}")
      )

      described_class.reconcile_assignment!(assignment)
      assignment.reload

      expect(assignment.error_message).to match(/attempt:2 backoff_until:/)
      second_delay = Time.parse(assignment.error_message[/backoff_until:(\S+)/, 1]) - Time.current
      expect(second_delay).to be > 45.seconds # BACKOFF_BASE * 2**1 = 60s — not pinned at 30s again
    end
  end

  describe "storage.mount dispatch dedupe" do
    it "does not spawn a second storage.mount task while one is already pending" do
      assignment # materialize — the after_commit trigger dispatches the first storage.mount task
      expect(System::Task.where(operable: node_instance, command: "storage.mount").count).to eq(1)

      described_class.reconcile_assignment!(assignment)

      expect(System::Task.where(operable: node_instance, command: "storage.mount").count).to eq(1)
    end
  end

  describe "storage.unmount dispatch dedupe" do
    before do
      assignment # materialize — the after_commit trigger dispatches an unrelated storage.mount task
      assignment.update_columns(enabled: false, status: "mounted", error_message: nil)
    end

    it "does not spawn a second storage.unmount task when two reconcile triggers race before the first's status transition commits" do
      # Simulate two independently-loaded assignment objects, mirroring two
      # concurrent reconcile triggers (after_commit + heartbeat/drift sweep)
      # that each read status: "mounted" before either one's
      # mark_status!("unmounting") commits.
      racer_a = System::StorageAssignment.find(assignment.id)
      racer_b = System::StorageAssignment.find(assignment.id)

      described_class.reconcile_assignment!(racer_a)
      expect(System::Task.where(operable: node_instance, command: "storage.unmount").count).to eq(1)

      described_class.reconcile_assignment!(racer_b)

      expect(System::Task.where(operable: node_instance, command: "storage.unmount").count).to eq(1)
    end
  end

  # IMP-026b8017d0b0 — #ensure_credential!'s expiry/needs_rotation? check
  # only catches a credential aging OUT; it says nothing about whether the
  # backend actually APPLIED the currently-active one. Without this, a
  # failed (or never-dispatched) storage.smb_user.apply task leaves samba on
  # the OLD password for up to ~89 days.
  describe "SMB stalled set_password re-dispatch" do
    let(:backend_instance) { create(:system_node_instance, account: account) }
    let(:smb_storage) do
      create(:file_storage, :smb, :node_mountable, account: account,
        configuration: {
          "mount_path" => "/mnt/smb-reconcile",
          "server_address" => "192.168.1.210",
          "share_name" => "reconcile-share",
          "export_host_node_instance_id" => backend_instance.id
        })
    end
    let(:smb_assignment) do
      create(:system_storage_assignment,
        account: account, file_storage_id: smb_storage.id,
        node_instance: node_instance, mount_path: "/mnt/smb-reconcile")
    end

    def smb_tasks
      System::Task.where(command: "storage.smb_user.apply", account_id: account.id).order(:created_at)
    end

    it "re-dispatches with create (never set_password) when the active credential's most recent task failed" do
      smb_assignment # materialize — after_commit reconcile auto-issues + dispatches "create"
      active = smb_assignment.reload.active_credential
      initial_task = smb_tasks.last
      initial_task.start!
      initial_task.fail!("samba-tool unreachable")

      described_class.reconcile_assignment!(smb_assignment)

      new_task = smb_tasks.last
      expect(new_task.id).not_to eq(initial_task.id)
      expect(new_task.options["action"]).to eq("create")
      expect(new_task.options["credential"]["id"]).to eq(active.id)
    end

    # The agent's setSambaPassword ONLY runs `samba-tool user setpassword`
    # (agent/internal/storage/smb_user.go) — it never creates a user. If the
    # credential's history includes a set_password dispatch (e.g. it is
    # itself the successor of an earlier rotation) and THAT is the most
    # recent failed task, re-dispatching with set_password again would fail
    # forever whenever the samba user does not actually exist yet.
    # createSambaUser creates-or-falls-through-to-setpassword, so "create"
    # is correct regardless of what the failed task's own action was.
    it "re-dispatches with create even when the most recently failed task was itself a set_password" do
      smb_assignment
      active = smb_assignment.reload.active_credential
      smb_tasks.first.start!
      smb_tasks.first.complete! # the original create succeeded

      failed_rotate_task = create(:system_task,
        account: account, operable: backend_instance, command: "storage.smb_user.apply",
        status: "pending",
        options: { "action" => "set_password", "credential" => { "id" => active.id }, "new_credential" => { "id" => active.id } })
      failed_rotate_task.start!
      failed_rotate_task.fail!("samba-tool unreachable")

      described_class.reconcile_assignment!(smb_assignment)

      new_task = smb_tasks.order(:created_at).last
      expect(new_task.id).not_to eq(failed_rotate_task.id)
      expect(new_task.options["action"]).to eq("create")
    end

    it "re-dispatches when no task exists at all for the active credential (defensive)" do
      smb_assignment
      smb_tasks.destroy_all

      described_class.reconcile_assignment!(smb_assignment)

      new_task = smb_tasks.last
      expect(new_task).to be_present
      expect(new_task.options["action"]).to eq("create")
    end

    it "re-dispatches when the active credential's most recent task was cancelled" do
      smb_assignment
      initial_task = smb_tasks.last
      initial_task.cancel!("stale task")

      described_class.reconcile_assignment!(smb_assignment)

      new_task = smb_tasks.last
      expect(new_task.id).not_to eq(initial_task.id)
      expect(new_task.options["action"]).to eq("create")
    end

    it "does not re-dispatch while a pending task for the active credential still exists" do
      smb_assignment
      before_count = smb_tasks.count

      described_class.reconcile_assignment!(smb_assignment)

      expect(smb_tasks.count).to eq(before_count)
    end

    it "does not re-dispatch once the task has completed" do
      smb_assignment
      initial_task = smb_tasks.last
      initial_task.start!
      initial_task.complete!
      before_count = smb_tasks.count

      described_class.reconcile_assignment!(smb_assignment)

      expect(smb_tasks.count).to eq(before_count)
    end
  end

  # IMP-e48612a32273 — the server-side remount decision. Reuses the same
  # SMB fixtures/helpers as the describe block above.
  describe "SMB remount decision" do
    let(:backend_instance) { create(:system_node_instance, account: account) }
    let(:smb_storage) do
      create(:file_storage, :smb, :node_mountable, account: account,
        configuration: {
          "mount_path" => "/mnt/smb-remount",
          "server_address" => "192.168.1.211",
          "share_name" => "remount-share",
          "export_host_node_instance_id" => backend_instance.id
        })
    end
    let(:smb_assignment) do
      create(:system_storage_assignment,
        account: account, file_storage_id: smb_storage.id,
        node_instance: node_instance, mount_path: "/mnt/smb-remount")
    end

    def mount_tasks
      System::Task.where(command: "storage.mount", account_id: account.id).order(:created_at)
    end

    # smb_assignment's own after_commit already dispatched a FIRST
    # storage.mount task while materializing — settle it (start!+complete!)
    # or dispatch_mount!'s own mount_task_already_pending? guard would block
    # every "second dispatch" assertion below regardless of the remount
    # logic under test.
    # Forced usernames (mirrors credential_issuer_spec.rb's own "SMB
    # cross-assignment username collision" fixture) — post-increment-2 real
    # derivation makes a genuinely scheme-crossing rotation unconstructable
    # naturally, and a scheme-crossing rotation is what leaves an old
    # credential "rotating" (see CredentialIssuer#revoke!'s own comment).
    before do
      allow_any_instance_of(System::StorageCredential)
        .to receive(:vault_credentials) { |cred| cred.metadata.slice("username") }
    end

    def smb_tasks
      System::Task.where(command: "storage.smb_user.apply", account_id: account.id).order(:created_at)
    end

    # Settles BOTH tasks the initial reconcile! dispatches for an SMB
    # assignment — the smb_user.apply "create" for the auto-issued
    # credential (to the backend) AND the storage.mount (to the consumer).
    # BLOCKER 2's #smb_provisioning_confirmed? guard reads the FORMER, so
    # any later test that manufactures a "genuinely differs" remount
    # scenario reusing this same active credential needs it already
    # "complete", exactly as a real, fully-settled first mount would be —
    # otherwise the guard (correctly) blocks a remount for a credential
    # whose OWN provisioning was never confirmed.
    # Rollout-skew review — completing a storage.mount task directly (not
    # through the real /complete endpoint) must ALSO stamp the "result" a
    # genuinely-confirming NEW agent would send: RemountCoordinator's
    # confirmation gate reads the "completed" event's "result" key (what the
    # AGENT reported), never `options` (what the SERVER dispatched) — see
    # that method's own comment. AASM's own #complete! bang method stages
    # its event under "data", never "result" (System::Task#stage_event's
    # default), so a bare start!+complete! here would silently never
    # confirm anything post-review — this helper is the fix.
    def complete_mount!(task)
      task.start! if task.pending?
      credential_id = task.options.dig("credential", "id")
      task.update!(
        status: "complete", progress: 100, completed_at: Time.current,
        events: (task.events || []) + [ {
          "type" => "completed", "message" => "ok",
          "result" => { "mounted_credential_id" => credential_id },
          "timestamp" => Time.current.iso8601
        } ]
      )
    end

    def settle_initial_mount!
      smb_assignment # materialize — after_commit reconcile dispatches both tasks
      smb_tasks.last&.tap { |t| t.start!; t.complete! }
      complete_mount!(mount_tasks.last)
    end

    def latest_create_task_for(credential)
      smb_tasks.where("options ->> 'action' = 'create'")
               .where("options -> 'credential' ->> 'id' = ?", credential.id).last
    end

    # A genuine scheme-crossing rotation via the real #rotate! path — leaves
    # `old_username`'s credential "rotating" (BLOCKER 3/rework fixture: NOT
    # "revoked" — see CredentialIssuer#revoke!'s own comment) and its
    # storage.smb_user.apply "create" task PENDING by default, so callers
    # exercising BLOCKER 2's provisioning-race guard get it un-settled.
    def rotate!(old_username: "n-legacyforced-ar#{SecureRandom.hex(4)}")
      settle_initial_mount!
      smb_assignment.update_columns(status: "mounted")
      old_credential = smb_assignment.reload.active_credential
      old_credential.update_columns(metadata: old_credential.metadata.merge("username" => old_username))
      new_credential = System::Storage::CredentialIssuer.new(assignment: smb_assignment).rotate!(old_credential)
      [ old_credential, new_credential ]
    end

    it "does NOT dispatch remount for the assignment's very first mount" do
      # smb_assignment's own after_commit already dispatched the FIRST
      # storage.mount task while materializing — inspect that one directly
      # rather than triggering a second reconcile (which would hit the
      # pending-task coalescing guard and dispatch nothing at all).
      smb_assignment
      task = mount_tasks.last
      expect(task).to be_present
      expect(task.options["remount"]).to be(false).or be_nil
    end

    # BLOCKER 3 (review) — a needless remount: the OLD signal
    # (@previously_mounted, "this assignment has been mounted before") is
    # gone entirely. A routine reconcile of an already-healthy, unchanged
    # mount must never ask for remount:true.
    it "does NOT remount when nothing rotated — mounted_credential_id already matches the credential being mounted" do
      settle_initial_mount! # RemountCoordinator's completion hook already set mounted_credential_id here
      smb_assignment.update_columns(status: "mounted")

      described_class.reconcile_assignment!(smb_assignment)

      expect(mount_tasks.order(:created_at).last.options["remount"]).to be(false).or be_nil
    end

    it "dispatches remount: true once mounted_credential_id genuinely differs from the credential being mounted" do
      settle_initial_mount!
      smb_assignment.update_columns(status: "mounted")
      active = smb_assignment.reload.active_credential
      stale = create(:system_storage_credential,
        storage_assignment: smb_assignment, node_instance: node_instance, kind: active.kind, status: "rotating")
      smb_assignment.update_columns(mounted_credential_id: stale.id)
      before_ids = mount_tasks.pluck(:id)

      described_class.reconcile_assignment!(smb_assignment)

      new_task = mount_tasks.where.not(id: before_ids).last
      expect(new_task).to be_present
      expect(new_task.options["remount"]).to be true
    end

    # BLOCKER 2 (review) — a remount must never race ahead of the samba
    # provisioning it depends on: reconcile! can rotate a credential (via
    # ensure_credential!) and dispatch_mount! in the SAME tick — this guard
    # is what stops that same-tick dispatch from racing the backend.
    describe "provisioning-race guard" do
      it "dispatches NO mount task while the smb create task for the new credential is still pending" do
        _old, new_credential = rotate!
        before_ids = mount_tasks.pluck(:id)

        described_class.reconcile_assignment!(smb_assignment)

        expect(mount_tasks.where.not(id: before_ids)).to be_empty
        expect(latest_create_task_for(new_credential).status).to eq("pending")
      end

      it "dispatches exactly one remount once the smb create task completes" do
        _old, new_credential = rotate!
        before_ids = mount_tasks.pluck(:id)
        described_class.reconcile_assignment!(smb_assignment) # no-ops per the guard above

        task = latest_create_task_for(new_credential)
        task.start!
        task.complete! # RemountCoordinator's after_update_commit hook dispatches the remount here

        new_mount_tasks = mount_tasks.where.not(id: before_ids)
        expect(new_mount_tasks.count).to eq(1)
        expect(new_mount_tasks.first.options["remount"]).to be true
        expect(new_mount_tasks.first.options["credential"]["id"]).to eq(new_credential.id)
      end

      it "does not block forever when no smb_user.apply task exists at all for the credential (defensive)" do
        # Via #dispatch_remount! directly (never routes through
        # ensure_credential!/#redispatch_stalled_smb_credential!, which
        # would otherwise dispatch one itself the moment it found none) —
        # #smb_provisioning_confirmed? must treat "no task record names
        # this credential" as confirmed, not as "wait forever".
        settle_initial_mount!
        smb_assignment.update_columns(status: "mounted")
        smb_assignment.storage_credentials.update_all(status: "revoked")
        active = create(:system_storage_credential,
          storage_assignment: smb_assignment, node_instance: node_instance, kind: "cifs_user_pass", status: "active")
        stale = create(:system_storage_credential,
          storage_assignment: smb_assignment, node_instance: node_instance, kind: "cifs_user_pass", status: "rotating")
        smb_assignment.update_columns(mounted_credential_id: stale.id)
        before_ids = mount_tasks.pluck(:id)

        described_class.dispatch_remount!(smb_assignment)

        new_task = mount_tasks.where.not(id: before_ids).last
        expect(new_task).to be_present
        expect(new_task.options["remount"]).to be true
        expect(new_task.options["credential"]["id"]).to eq(active.id)
      end
    end

    describe "previous_credential_ids" do
      it "carries every ROTATING credential's id (plural — rework hole (b))" do
        before_ids = mount_tasks.pluck(:id)
        old1, new1 = rotate!
        latest_create_task_for(new1).tap { |t| t.start!; t.complete! } # dispatches the remount for new1

        remount_task = mount_tasks.where.not(id: before_ids).last
        expect(remount_task.options["previous_credential_ids"]).to contain_exactly(old1.id)
      end

      it "omits previous_credential_ids on a non-remount dispatch" do
        smb_assignment
        task = mount_tasks.last
        expect(task.options).not_to have_key("previous_credential_ids")
      end
    end

    describe ".dispatch_remount!" do
      it "dispatches a remount using the assignment's current active_credential" do
        settle_initial_mount!
        smb_assignment.update_columns(status: "mounted")
        active = smb_assignment.reload.active_credential
        stale = create(:system_storage_credential,
          storage_assignment: smb_assignment, node_instance: node_instance, kind: active.kind, status: "rotating")
        smb_assignment.update_columns(mounted_credential_id: stale.id)
        before_ids = mount_tasks.pluck(:id)

        described_class.dispatch_remount!(smb_assignment)

        new_task = mount_tasks.where.not(id: before_ids).last
        expect(new_task).to be_present
        expect(new_task.options["remount"]).to be true
        expect(new_task.options["credential"]["id"]).to eq(active.id)
      end

      it "does nothing when the assignment has no active credential" do
        settle_initial_mount!
        smb_assignment.update_columns(status: "mounted")
        smb_assignment.storage_credentials.update_all(status: "revoked")
        before_count = mount_tasks.count

        described_class.dispatch_remount!(smb_assignment)

        expect(mount_tasks.count).to eq(before_count)
      end
    end

    # IMP-e48612a32273 — the drift-detection safety net: reconcile_instance!
    # (the heartbeat-triggered per-instance sweep) now also picks up a
    # mounted assignment whose mounted_credential_id has drifted from its
    # own active_credential, even though pending_reconcile alone would
    # exclude it (status "mounted" is deliberately excluded there).
    describe ".reconcile_instance! drift pickup" do
      it "re-dispatches a mounted assignment whose mounted_credential_id no longer matches its active credential" do
        settle_initial_mount!
        smb_assignment.update_columns(status: "mounted")
        active = smb_assignment.reload.active_credential
        stale = create(:system_storage_credential,
          storage_assignment: smb_assignment, node_instance: node_instance, kind: active.kind, status: "revoked")
        smb_assignment.update_columns(mounted_credential_id: stale.id)
        before_ids = mount_tasks.pluck(:id)

        described_class.reconcile_instance!(node_instance)

        expect(mount_tasks.where.not(id: before_ids)).not_to be_empty
      end

      it "does not re-dispatch a mounted assignment whose mounted_credential_id already matches" do
        settle_initial_mount!
        smb_assignment.update_columns(status: "mounted")
        active = smb_assignment.reload.active_credential
        smb_assignment.update_columns(mounted_credential_id: active.id)
        before_count = mount_tasks.count

        described_class.reconcile_instance!(node_instance)

        expect(mount_tasks.count).to eq(before_count)
      end
    end
  end

  # IMP-9ffb9b2407da — NFS counterpart of the SMB re-dispatch above. Reuses
  # the top-level `assignment`/`file_storage` (already NFS-configured).
  # Unlike SMB, the exports.apply payload names no credential in its shape
  # — it's a per-STORAGE full rebuild (IMP-ba7956c5b38d) — so "does this
  # task cover my credential" is a MEMBERSHIP check against the rebuild's
  # own `included_credential_ids`, not a timing comparison. A timing-only
  # check (task created at/after the credential row) looks equivalent but
  # is wrong: a rebuild while the assignment is disabled correctly
  # EXCLUDES it and still completes AFTER the credential row exists, which
  # a timing check would wrongly call "safe" — see the disable/re-enable
  # spec below, which is the exact bug this membership check exists to
  # close.
  describe "NFS stalled exports rebuild re-dispatch" do
    # Overrides the outer node_instance/assignment (scoped to this describe
    # block only) with a peer-enrolled one — the top-level `assignment`
    # fixture never enrolls an Sdwan::Peer, so its credential's metadata
    # peer_ip is always nil and every entry gets WARN-skipped (invisible to
    # every pre-existing test here, none of which inspect entries/
    # included_credential_ids content — this block is the first to).
    let(:network) { create(:sdwan_network, account: account) }
    let(:node_instance) do
      instance = create(:system_node_instance, account: account)
      ::Sdwan::PeerEnroller.call(network: network, node_instance: instance)
      instance
    end
    let(:assignment) do
      create(:system_storage_assignment,
        account: account, file_storage_id: file_storage.id, node_instance: node_instance,
        sdwan_network: network, mount_path: "/mnt/test")
    end

    def exports_tasks
      System::Task.where(command: "storage.exports.apply", account_id: account.id).order(:created_at)
    end

    def backend_node_instance
      System::NodeInstance.find(file_storage.configuration["export_host_node_instance_id"])
    end

    # A hand-built exports.apply task for this storage, independent of any
    # real assignment's reconcile — lets the membership tests below craft
    # exactly the included_credential_ids a real rebuild would have
    # produced without needing a second real assignment.
    def build_exports_task(included_credential_ids:)
      create(:system_task,
        account: account, operable: backend_node_instance, command: "storage.exports.apply",
        status: "pending",
        options: {
          "storage_id" => file_storage.id, "account_id" => account.id,
          "action" => "revoke", "entries" => [], "included_credential_ids" => included_credential_ids
        })
    end

    it "rebuilds (reconcile!) when the storage's most recent exports task failed" do
      assignment # materialize — after_commit reconcile auto-issues + dispatches a rebuild
      active = assignment.reload.active_credential
      initial_task = exports_tasks.last
      initial_task.start!
      initial_task.fail!("agent unreachable")

      described_class.reconcile_assignment!(assignment)

      new_task = exports_tasks.last
      expect(new_task.id).not_to eq(initial_task.id)
      expect(new_task.options["action"]).to eq("revoke")
      expect(active.reload.status).to eq("active") # unaffected — this is a rebuild, not a rotation
    end

    it "rebuilds when the storage's most recent exports task was cancelled" do
      assignment
      initial_task = exports_tasks.last
      initial_task.cancel!("stale task")

      described_class.reconcile_assignment!(assignment)

      new_task = exports_tasks.last
      expect(new_task.id).not_to eq(initial_task.id)
    end

    it "rebuilds when no exports task exists at all for the storage (defensive / pre-existing credential)" do
      assignment
      exports_tasks.destroy_all

      described_class.reconcile_assignment!(assignment)

      expect(exports_tasks.last).to be_present
    end

    it "does not rebuild while a pending exports task for the storage still exists" do
      assignment
      before_count = exports_tasks.count

      described_class.reconcile_assignment!(assignment)

      expect(exports_tasks.count).to eq(before_count)
    end

    it "does not rebuild once a completed exports task's included_credential_ids contains the credential" do
      assignment
      active = assignment.reload.active_credential
      initial_task = exports_tasks.last
      initial_task.start!
      initial_task.complete!
      expect(initial_task.options["included_credential_ids"]).to include(active.id) # sanity — precondition for the assertion below
      before_count = exports_tasks.count

      described_class.reconcile_assignment!(assignment)

      expect(exports_tasks.count).to eq(before_count)
    end

    # The critical regression guard: a timing-only check (task created
    # at/after the credential row) would call this SAFE — excluding_task is
    # created strictly after the credential exists. Membership correctly
    # says otherwise, because the rebuild that produced it didn't include
    # this credential.
    it "rebuilds when the latest completed exports task was created after the credential but does not include it" do
      assignment
      active = assignment.reload.active_credential
      initial_task = exports_tasks.last
      initial_task.start!
      initial_task.complete!

      excluding_task = build_exports_task(included_credential_ids: [])
      excluding_task.start!
      excluding_task.complete!

      described_class.reconcile_assignment!(assignment)

      new_task = exports_tasks.last
      expect(new_task.id).not_to eq(excluding_task.id)
      expect(new_task.options["included_credential_ids"]).to include(active.id)
    end

    # Mutation guard: the ORIGINAL (pre-membership) timing check would also
    # have caught this simpler case — a completed task that predates the
    # credential entirely can't possibly include it. Kept so a future
    # change can't silently regress this case while "fixing" something
    # else.
    it "rebuilds when the latest completed exports task predates the credential" do
      assignment
      active = assignment.reload.active_credential
      exports_tasks.destroy_all

      predating_task = build_exports_task(included_credential_ids: [])
      predating_task.start!
      predating_task.complete!
      predating_task.update_columns(created_at: active.created_at - 1.hour)

      described_class.reconcile_assignment!(assignment)

      new_task = exports_tasks.last
      expect(new_task.id).not_to eq(predating_task.id)
    end

    # The exact reported bug: a rebuild while disabled correctly excludes
    # the assignment and completes AFTER the credential row exists — a
    # TIMING check would call that "safe" forever (the drift sensor would
    # re-run and skip every time); membership correctly sees this
    # credential was never actually re-exported once re-enabled.
    it "re-exports a credential once re-enabled, after a rebuild while disabled correctly excluded it" do
      assignment
      active = assignment.reload.active_credential
      exports_tasks.last.tap { |t| t.start!; t.complete! } # settle the initial dispatch — an unrelated still-pending task would mask everything below behind the coalescing guard

      assignment.update_columns(enabled: false) # bypass callbacks — isolate the rebuild below from dispatch_unmount!/mark_status! noise
      ::System::Storage::NfsExportManager.reconcile!(storage: file_storage)
      excluding_task = exports_tasks.last
      excluding_task.start!
      excluding_task.complete!
      expect(excluding_task.options["included_credential_ids"]).not_to include(active.id) # sanity — it really was excluded while disabled

      assignment.update_columns(enabled: true, status: "provisioning", error_message: nil)

      described_class.reconcile_assignment!(assignment)

      new_task = exports_tasks.last
      expect(new_task.id).not_to eq(excluding_task.id)
      expect(new_task.options["included_credential_ids"]).to include(active.id)
    end

    # Coalescing — the operator's explicit "storm" concern: several
    # assignments sharing ONE storage all reconciling in the same tick must
    # not each fire their own rebuild while one is already in flight.
    it "does not fire a redundant rebuild when a SIBLING assignment on the same storage already has one pending" do
      assignment # materialize — dispatches the first rebuild for this storage
      exports_tasks.last.tap { |t| t.start!; t.complete! } # settle it before the sibling's own dispatch

      other_instance = create(:system_node_instance, account: account)
      create(:system_storage_assignment, # other_assignment — its own after_commit issue! dispatches a fresh, still-pending rebuild for the SAME storage
        account: account, file_storage_id: file_storage.id,
        node_instance: other_instance, mount_path: "/mnt/other-reconcile")
      before_count = exports_tasks.count

      described_class.reconcile_assignment!(assignment)

      expect(exports_tasks.count).to eq(before_count)
    end

    # A credential with no peer_ip can never be exported —
    # NfsExportManager#reconcile! itself WARN-skips it. Without an early
    # return here, this assignment would look "not included in the last
    # rebuild" (it never can be) on EVERY reconcile tick and queue another
    # rebuild forever, for a row nothing can fix by rebuilding again.
    it "does not queue a rebuild for a credential with no peer_ip, logging at WARN instead" do
      allow_any_instance_of(System::StorageCredential)
        .to receive(:vault_credentials) { |instance| instance.metadata.slice("peer_ip") }

      assignment # materialize
      active = assignment.reload.active_credential
      exports_tasks.last.tap { |t| t.start!; t.complete! } # settle the initial dispatch, or the coalescing (still-pending) guard masks everything below
      active.update_columns(metadata: active.metadata.merge("peer_ip" => nil))

      # A rebuild while the credential is already peerless correctly
      # excludes it (see nfs_export_manager_spec's own peerless test) and
      # completes — WITHOUT the early-return guard below, the next
      # reconcile tick would see "not included in the last rebuild" (true,
      # but unfixable by rebuilding again) and queue yet another one,
      # forever.
      ::System::Storage::NfsExportManager.reconcile!(storage: file_storage)
      exports_tasks.last.tap { |t| t.start!; t.complete! }
      before_count = exports_tasks.count

      warnings = []
      allow(Rails.logger).to receive(:warn) { |msg| warnings << msg }

      described_class.reconcile_assignment!(assignment)

      expect(exports_tasks.count).to eq(before_count)
      expect(warnings.any? { |w| w.include?(assignment.id) && w.include?(active.id) }).to be true
    end
  end
end
