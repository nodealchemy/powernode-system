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
end
