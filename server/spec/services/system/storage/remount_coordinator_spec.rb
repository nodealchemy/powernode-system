# frozen_string_literal: true

require "rails_helper"

# IMP-e48612a32273 Amendment C — the cross-account scoping/no-op-and-log
# guarantee. Each entry point re-resolves every id it reads out of a task's
# OWN options through a query scoped to that SAME task's account_id, and
# no-ops-and-logs on a mismatch rather than raising, so one malformed/stale
# task can't take the whole after_update_commit chain down for every other
# task. The ordinary chain behavior (dispatch/flip/retire) is covered
# end-to-end in status_smb_remount_chain_spec.rb (Amendment B) and
# assignment_reconciliation_service_spec.rb; this file is scoping-only.
RSpec.describe System::Storage::RemountCoordinator do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:backend_instance) { create(:system_node_instance, account: account) }
  let(:node_instance) { create(:system_node_instance, account: account) }
  let(:smb_storage) do
    create(:file_storage, :smb, :node_mountable, account: account,
      configuration: {
        "mount_path" => "/mnt/smb-scope", "server_address" => "192.168.1.213",
        "share_name" => "scope-share", "export_host_node_instance_id" => backend_instance.id
      })
  end
  let(:assignment) do
    create(:system_storage_assignment,
      account: account, file_storage_id: smb_storage.id, node_instance: node_instance, mount_path: "/mnt/smb-scope")
  end

  def mount_tasks
    System::Task.where(command: "storage.mount", account_id: account.id).order(:created_at)
  end

  def smb_tasks
    System::Task.where(command: "storage.smb_user.apply", account_id: account.id).order(:created_at)
  end

  def capture_errors
    errors = []
    allow(Rails.logger).to receive(:error) { |msg| errors << msg }
    yield
    errors
  end

  # Rollout-skew review — the confirmation gate reads the "completed"
  # event's "result" key (what the agent actually reported), never
  # `options` (what the server dispatched). `mounted_credential_id: :auto`
  # confirms with THIS task's own dispatched credential id (a well-behaved
  # NEW agent); pass an explicit id to simulate a MISMATCH, or omit the
  # keyword entirely (default nil, no key added) to simulate an OLD
  # agent's shape.
  # Built already-"complete" in ONE create call, deliberately — NOT
  # create-then-update!(status: "complete"): System::Task's own
  # after_update_commit hook (on: :update) would fire a SECOND, automatic
  # call to RemountCoordinator on that update, before this file's own
  # explicit `described_class.handle_completed_mount_task!(task)` call —
  # doubling the effect and making these unit tests silently pass on the
  # AUTOMATIC trigger rather than the explicit one under test. `create`
  # never fires an on: :update hook, so this stays a true unit test.
  def completed_mount_task(options:, mounted_credential_id: :unset)
    result = {}
    case mounted_credential_id
    when :unset
      # no key at all — the old-agent shape
    when :auto
      result["mounted_credential_id"] = options.dig("credential", "id")
    else
      result["mounted_credential_id"] = mounted_credential_id
    end
    create(:system_task,
      account: account, operable: node_instance, command: "storage.mount", status: "complete", options: options,
      events: [ { "type" => "completed", "message" => "ok", "result" => result, "timestamp" => Time.current.iso8601 } ])
  end

  describe "#dispatch_remount_for_completed_smb_task!" do
    it "no-ops and logs when the completed task's credential belongs to a DIFFERENT account" do
      credential = assignment.reload.active_credential
      foreign_task = create(:system_task,
        account: other_account, operable: create(:system_node_instance, account: other_account),
        command: "storage.smb_user.apply", status: "complete",
        options: { "action" => "create", "credential" => { "id" => credential.id } })

      before_count = mount_tasks.count
      errors = capture_errors { described_class.dispatch_remount_for_completed_smb_task!(foreign_task) }

      expect(mount_tasks.count).to eq(before_count)
      expect(errors.any? { |e| e.include?(foreign_task.id) && e.include?(credential.id) }).to be true
    end

    it "no-ops (no raise) when the named credential id does not exist at all" do
      task = create(:system_task,
        account: account, operable: backend_instance, command: "storage.smb_user.apply", status: "complete",
        options: { "action" => "create", "credential" => { "id" => SecureRandom.uuid } })

      expect { described_class.dispatch_remount_for_completed_smb_task!(task) }.not_to raise_error
    end
  end

  describe "#dispatch_remount_for_completed_smb_task! (BLOCKER 3)" do
    it "dispatches NO mount task when mounted_credential_id already equals this credential's id" do
      credential = assignment.reload.active_credential
      assignment.update_columns(status: "mounted", mounted_credential_id: credential.id)
      task = create(:system_task,
        account: account, operable: backend_instance, command: "storage.smb_user.apply", status: "complete",
        options: { "action" => "create", "credential" => { "id" => credential.id } })

      before_count = mount_tasks.count
      described_class.dispatch_remount_for_completed_smb_task!(task)

      expect(mount_tasks.count).to eq(before_count)
    end
  end

  describe "#handle_completed_mount_task! (rework hole (a))" do
    # A rotation that happened while the assignment was UNMOUNTED gets an
    # ORDINARY (non-remount) mount once it's (re-)enabled — that mount is
    # what confirms the rotation too, so retirement must not be gated on
    # options["remount"] == true.
    it "retires an OTHER rotating credential on an ordinary (non-remount) mount completion" do
      credential = assignment.reload.active_credential
      rotating = create(:system_storage_credential,
        storage_assignment: assignment, node_instance: node_instance, kind: credential.kind, status: "rotating")
      task_options = { "assignment_id" => assignment.id, "credential" => { "id" => credential.id } } # no "remount" key at all

      before_ids = smb_tasks.pluck(:id)
      task = completed_mount_task(options: task_options, mounted_credential_id: :auto)
      described_class.handle_completed_mount_task!(task)

      expect(assignment.reload.mounted_credential_id).to eq(credential.id)
      delete_task = smb_tasks.where.not(id: before_ids).where("options ->> 'action' = 'delete'").last
      expect(delete_task).to be_present
      expect(delete_task.options["credential"]["id"]).to eq(rotating.id)
      expect(rotating.reload.status).to eq("revoked")
    end

    it "no-ops and logs when the task's assignment_id belongs to a DIFFERENT account" do
      foreign_assignment = create(:system_storage_assignment,
        account: other_account,
        file_storage_id: create(:file_storage, :smb, :node_mountable, account: other_account,
          configuration: {
            "mount_path" => "/mnt/foreign", "server_address" => "192.168.1.214",
            "share_name" => "foreign-share",
            "export_host_node_instance_id" => create(:system_node_instance, account: other_account).id
          }).id,
        node_instance: create(:system_node_instance, account: other_account), mount_path: "/mnt/foreign")

      # A task claiming account: account (this test's own account) but
      # naming an assignment_id that actually belongs to other_account.
      task = create(:system_task,
        account: account, operable: node_instance, command: "storage.mount", status: "complete",
        options: { "assignment_id" => foreign_assignment.id, "credential" => { "id" => SecureRandom.uuid } })

      errors = capture_errors { described_class.handle_completed_mount_task!(task) }

      expect(foreign_assignment.reload.mounted_credential_id).to be_nil
      expect(errors.any? { |e| e.include?(task.id) && e.include?(foreign_assignment.id) }).to be true
    end

    it "records mounted_credential_id when the assignment is correctly scoped to the task's own account" do
      credential = assignment.reload.active_credential
      task = completed_mount_task(
        options: { "assignment_id" => assignment.id, "credential" => { "id" => credential.id } },
        mounted_credential_id: :auto
      )

      described_class.handle_completed_mount_task!(task)

      expect(assignment.reload.mounted_credential_id).to eq(credential.id)
    end
  end

  # Rollout-skew review — the confirmation gate itself: a completion alone
  # is not proof, an old (pre-remount-aware) agent's no-op start reports
  # success too. Only a completion whose OWN result echoes back this exact
  # credential id may flip mounted_credential_id or retire anything.
  describe "#handle_completed_mount_task! (rollout-skew confirmation gate)" do
    it "an old-shape completion (no mounted_credential_id at all) does NOT flip or retire, and sets error_message" do
      credential = assignment.reload.active_credential
      rotating = create(:system_storage_credential,
        storage_assignment: assignment, node_instance: node_instance, kind: credential.kind, status: "rotating")
      task = completed_mount_task(options: { "assignment_id" => assignment.id, "credential" => { "id" => credential.id } })

      before_ids = smb_tasks.pluck(:id)
      described_class.handle_completed_mount_task!(task)

      expect(assignment.reload.mounted_credential_id).to be_nil
      expect(smb_tasks.where.not(id: before_ids)).to be_empty
      expect(rotating.reload.status).to eq("rotating") # untouched
      expect(assignment.error_message).to eq("agent did not confirm mounted credential (agent upgrade needed?)")
    end

    it "a MISMATCHED confirmed id does NOT flip or retire, and sets error_message" do
      credential = assignment.reload.active_credential
      rotating = create(:system_storage_credential,
        storage_assignment: assignment, node_instance: node_instance, kind: credential.kind, status: "rotating")
      task = completed_mount_task(
        options: { "assignment_id" => assignment.id, "credential" => { "id" => credential.id } },
        mounted_credential_id: SecureRandom.uuid
      )

      before_ids = smb_tasks.pluck(:id)
      described_class.handle_completed_mount_task!(task)

      expect(assignment.reload.mounted_credential_id).to be_nil
      expect(smb_tasks.where.not(id: before_ids)).to be_empty
      expect(rotating.reload.status).to eq("rotating")
      expect(assignment.error_message).to eq("agent did not confirm mounted credential (agent upgrade needed?)")
    end

    it "a MATCHING confirmed id flips mounted_credential_id AND retires rotating credentials" do
      credential = assignment.reload.active_credential
      rotating = create(:system_storage_credential,
        storage_assignment: assignment, node_instance: node_instance, kind: credential.kind, status: "rotating")
      task = completed_mount_task(
        options: { "assignment_id" => assignment.id, "credential" => { "id" => credential.id } },
        mounted_credential_id: :auto
      )

      before_ids = smb_tasks.pluck(:id)
      described_class.handle_completed_mount_task!(task)

      expect(assignment.reload.mounted_credential_id).to eq(credential.id)
      delete_task = smb_tasks.where.not(id: before_ids).where("options ->> 'action' = 'delete'").last
      expect(delete_task).to be_present
      expect(delete_task.options["credential"]["id"]).to eq(rotating.id)
      expect(rotating.reload.status).to eq("revoked")
    end

    # Review fix (1) — an `already_active: true` completion (the agent's
    # OWN honest report that it changed nothing) for a credential the
    # assignment ALREADY reads as mounted is a healthy, routine reconcile —
    # not an anomaly. Must not scare-log/error_message it.
    it "an already_active completion for the ALREADY-confirmed credential sets no error_message" do
      credential = assignment.reload.active_credential
      assignment.update_columns(mounted_credential_id: credential.id) # already confirmed from an earlier mount
      task = completed_mount_task(options: { "assignment_id" => assignment.id, "credential" => { "id" => credential.id } }) # no result key — already_active shape

      described_class.handle_completed_mount_task!(task)

      expect(assignment.reload.mounted_credential_id).to eq(credential.id) # unchanged
      expect(assignment.error_message).to be_nil
    end

    # Review fix (2) — the note must not clobber a pre-existing
    # attempt:/backoff_until: pair (#record_failure!'s own counter) or a
    # remount_fail= counter (#handle_failed_mount_task!'s) already sitting
    # in error_message.
    it "appends the note, preserving a pre-existing attempt:/backoff_until: pair" do
      credential = assignment.reload.active_credential
      backoff_until = 1.hour.from_now.iso8601
      assignment.update_columns(error_message: "attempt:3 backoff_until:#{backoff_until} RuntimeError: boom")
      task = completed_mount_task(options: { "assignment_id" => assignment.id, "credential" => { "id" => credential.id } })

      described_class.handle_completed_mount_task!(task)

      expect(assignment.reload.error_message).to include("attempt:3")
      expect(assignment.error_message).to include("backoff_until:#{backoff_until}")
      expect(assignment.error_message).to include("agent did not confirm mounted credential (agent upgrade needed?)")
    end

    it "is idempotent: does not duplicate the note across repeated unconfirmed completions" do
      credential = assignment.reload.active_credential
      task1 = completed_mount_task(options: { "assignment_id" => assignment.id, "credential" => { "id" => credential.id } })
      described_class.handle_completed_mount_task!(task1)

      task2 = completed_mount_task(options: { "assignment_id" => assignment.id, "credential" => { "id" => credential.id } })
      described_class.handle_completed_mount_task!(task2)

      note = "agent did not confirm mounted credential (agent upgrade needed?)"
      expect(assignment.reload.error_message.scan(note).count).to eq(1)
    end
  end

  describe "#handle_failed_mount_task! (non-blocking review item — consecutive-failure counter)" do
    it "records an increasing remount_fail count and the agent's reported error text across repeated failures" do
      assignment.update_columns(status: "mounted")

      3.times do |i|
        task = create(:system_task,
          account: account, operable: node_instance, command: "storage.mount", status: "failed",
          options: { "assignment_id" => assignment.id, "remount" => true },
          error_message: "systemctl restart: exit status 32: target is busy")
        described_class.handle_failed_mount_task!(task)
        assignment.update_columns(status: "mounted") # reconcile/drift would re-admit it; simulate the next tick finding it "mounted" again before failing once more
        expect(assignment.reload.error_message).to include("remount_fail=#{i + 1}")
      end

      expect(assignment.reload.error_message).to include("target is busy")
    end

    # Review nit — "remount_fail=" must never be mistaken for
    # #record_failure!'s own "attempt:" counter (a DIFFERENT exception-retry
    # backoff, tracked on the same free-text error_message field).
    it "does not collide with record_failure!'s own attempt: counter" do
      assignment.update_columns(status: "mounted", error_message: "attempt:7 backoff_until:#{1.hour.from_now.iso8601} RuntimeError: boom")

      task = create(:system_task,
        account: account, operable: node_instance, command: "storage.mount", status: "failed",
        options: { "assignment_id" => assignment.id, "remount" => true },
        error_message: "systemctl restart: exit status 32: target is busy")
      described_class.handle_failed_mount_task!(task)

      expect(assignment.reload.error_message).to include("remount_fail=1") # not remount_fail=8
    end
  end

  describe "#handle_failed_mount_task!" do
    it "no-ops and logs when the task's assignment_id belongs to a DIFFERENT account" do
      foreign_assignment = create(:system_storage_assignment,
        account: other_account,
        file_storage_id: create(:file_storage, :smb, :node_mountable, account: other_account,
          configuration: {
            "mount_path" => "/mnt/foreign2", "server_address" => "192.168.1.215",
            "share_name" => "foreign-share-2",
            "export_host_node_instance_id" => create(:system_node_instance, account: other_account).id
          }).id,
        node_instance: create(:system_node_instance, account: other_account), mount_path: "/mnt/foreign2")
      foreign_assignment.update_columns(status: "mounted")

      task = create(:system_task,
        account: account, operable: node_instance, command: "storage.mount", status: "failed",
        options: { "assignment_id" => foreign_assignment.id, "remount" => true })

      errors = capture_errors { described_class.handle_failed_mount_task!(task) }

      expect(foreign_assignment.reload.status).to eq("mounted") # untouched
      expect(errors.any? { |e| e.include?(task.id) && e.include?(foreign_assignment.id) }).to be true
    end
  end
end
