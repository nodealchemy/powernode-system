# frozen_string_literal: true

require "rails_helper"

# IMP-e48612a32273 Amendment B — drives the SMB consumer remount-on-rotation
# chain through the REAL node_api status endpoints
# (acknowledge/complete/fail), not through System::Task directly. This is
# the spec Amendment B specifically required: the only production write
# path to "complete"/"failed" is StatusController's raw `operation.update!`,
# never an AASM bang method, so a callback wired to the wrong hook shape
# would pass a model-level spec while silently never firing here.
RSpec.describe "Api::V1::System::NodeApi::Status SMB remount chain", type: :request do
  let(:account) { create(:account) }
  let(:backend_instance) { create(:system_node_instance, account: account) }
  let(:node) { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, :running, node: node, account: account) }

  # storage.mount tasks are dispatched to the CONSUMER (assignment.node_instance
  # == instance); storage.smb_user.apply tasks are dispatched to the SMB
  # BACKEND (SmbUserManager#backend_node_instance_id ==
  # export_host_node_instance_id == backend_instance) — two different
  # `current_instance`s, so each needs its own cert/headers.
  let!(:active_cert) do
    System::NodeCertificate.create!(
      node_instance: instance, serial: SecureRandom.hex(16), subject: "CN=#{instance.id}",
      not_before: 1.hour.ago, not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
    )
  end
  let!(:backend_cert) do
    System::NodeCertificate.create!(
      node_instance: backend_instance, serial: SecureRandom.hex(16), subject: "CN=#{backend_instance.id}",
      not_before: 1.hour.ago, not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
    )
  end
  let(:headers) { { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) } }
  let(:backend_headers) { { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{backend_instance.id}")) } }

  let(:smb_storage) do
    create(:file_storage, :smb, :node_mountable, account: account,
      configuration: {
        "mount_path" => "/mnt/smb-chain", "server_address" => "192.168.1.212",
        "share_name" => "chain-share", "export_host_node_instance_id" => backend_instance.id
      })
  end
  let(:assignment) do
    create(:system_storage_assignment,
      account: account, file_storage_id: smb_storage.id, node_instance: instance, mount_path: "/mnt/smb-chain")
  end

  # storage.mount tasks report as the consumer; storage.smb_user.apply tasks
  # report as the SMB backend — see the headers/backend_headers comment above.
  def headers_for(task)
    task.command == "storage.smb_user.apply" ? backend_headers : headers
  end

  def acknowledge!(task)
    post "/api/v1/system/node_api/status/tasks/#{task.id}/acknowledge", headers: headers_for(task)
    expect(response).to have_http_status(:ok)
  end

  # Rollout-skew review — a storage.mount completion's default result now
  # confirms (`mounted_credential_id` echoing the credential THIS task
  # named), matching a genuinely up-to-date agent, so every EXISTING call
  # site here keeps testing what it always tested (remount dispatch/
  # ordering) rather than silently starting to fail the new confirmation
  # gate. The confirmation gate itself gets its OWN dedicated tests below,
  # which override `result:` explicitly to the old-agent/mismatched shapes.
  def complete!(task, result: nil)
    acknowledge!(task) if task.reload.status == "pending"
    result ||= default_completion_result_for(task)
    post "/api/v1/system/node_api/status/tasks/#{task.id}/complete",
         params: { result: result }.to_json, headers: headers_for(task).merge("Content-Type" => "application/json")
    expect(response).to have_http_status(:ok)
  end

  def default_completion_result_for(task)
    return { "ok" => true } unless task.command == "storage.mount"

    { "mounted_credential_id" => task.options.dig("credential", "id") }
  end

  def fail!(task, error_message: "systemctl restart: exit status 32: target is busy")
    acknowledge!(task) if task.reload.status == "pending"
    post "/api/v1/system/node_api/status/tasks/#{task.id}/fail",
         params: { error_message: error_message }.to_json, headers: headers_for(task).merge("Content-Type" => "application/json")
    expect(response).to have_http_status(:ok)
  end

  def smb_tasks
    System::Task.where(command: "storage.smb_user.apply", account_id: account.id).order(:created_at)
  end

  def mount_tasks
    System::Task.where(command: "storage.mount", account_id: account.id).order(:created_at)
  end

  # Materializes the assignment as already mounted with a settled first
  # credential (mount task AND its smb_user.apply "create" task both
  # complete — BLOCKER 2's #smb_provisioning_confirmed? guard reads the
  # latter, so a later genuine rotation's remount isn't blocked on an
  # unrelated, still-pending FIRST-issuance task), driven through the real
  # endpoints throughout (Amendment B).
  def settle_initial_mount_via_real_endpoints!
    assignment
    complete!(smb_tasks.where("options ->> 'action' = 'create'").last)
    complete!(mount_tasks.last)
    assignment.update_columns(status: "mounted")
  end

  # Forced usernames (mirrors credential_issuer_spec.rb's own "SMB
  # cross-assignment username collision" fixture) — post-increment-2 real
  # derivation makes a naturally scheme-crossing rotation unconstructable,
  # and a scheme-crossing rotation is required for there to be an old
  # identity to retire at all (BLOCKER 3, review, means a SAME-credential
  # completion dispatches no remount — there is no "just reuse the initial
  # credential" shortcut left).
  before do
    allow_any_instance_of(System::StorageCredential)
      .to receive(:vault_credentials) { |cred| cred.metadata.slice("username") }
  end

  def perform_scheme_crossing_rotation!
    settle_initial_mount_via_real_endpoints!
    old_credential = assignment.reload.active_credential
    old_credential.update_columns(metadata: old_credential.metadata.merge("username" => "n-legacyforced0001"))
    new_credential = ::System::Storage::CredentialIssuer.new(assignment: assignment).rotate!(old_credential)
    [ old_credential, new_credential ]
  end

  it "completing a samba create task (real endpoint) dispatches a remount storage.mount task" do
    _old_credential, new_credential = perform_scheme_crossing_rotation!
    create_task = smb_tasks.where("options ->> 'action' = 'create'")
                           .where("options -> 'credential' ->> 'id' = ?", new_credential.id).last
    before_ids = mount_tasks.pluck(:id)

    complete!(create_task)

    new_task = mount_tasks.where.not(id: before_ids).last
    expect(new_task).to be_present
    expect(new_task.options["remount"]).to be true
  end

  it "the remount payload carries ids only — never secret material (Amendment C)" do
    _old_credential, new_credential = perform_scheme_crossing_rotation!
    create_task = smb_tasks.where("options ->> 'action' = 'create'")
                           .where("options -> 'credential' ->> 'id' = ?", new_credential.id).last
    before_ids = mount_tasks.pluck(:id)

    complete!(create_task)

    new_task = mount_tasks.where.not(id: before_ids).last
    payload = new_task.options
    expect(payload["credential"].keys).to match_array(%w[id kind url])
    expect(payload.to_json).not_to match(/password/i)
  end

  context "with a genuine scheme-crossing rotation" do
    it "completing that remount's storage.mount task (real endpoint) flips mounted_credential_id and dispatches the old user's delete" do
      old_credential, new_credential = perform_scheme_crossing_rotation!
      create_task = smb_tasks.where("options ->> 'action' = 'create'")
                             .where("options -> 'credential' ->> 'id' = ?", new_credential.id).last

      before_mount_ids = mount_tasks.pluck(:id)
      complete!(create_task)
      remount_task = mount_tasks.where.not(id: before_mount_ids).last
      expect(remount_task.options.dig("credential", "id")).to eq(new_credential.id)

      before_delete_ids = smb_tasks.where("options ->> 'action' = 'delete'").pluck(:id)
      complete!(remount_task)

      expect(assignment.reload.mounted_credential_id).to eq(new_credential.id)

      delete_task = smb_tasks.where("options ->> 'action' = 'delete'").where.not(id: before_delete_ids).last
      expect(delete_task).to be_present
      expect(delete_task.options["credential"]["id"]).to eq(old_credential.id)
      expect(old_credential.reload.status).to eq("revoked")
    end

    it "a FAILED remount (real endpoint) marks the assignment degraded and dispatches NO delete" do
      old_credential, new_credential = perform_scheme_crossing_rotation!
      create_task = smb_tasks.where("options ->> 'action' = 'create'")
                             .where("options -> 'credential' ->> 'id' = ?", new_credential.id).last
      complete!(create_task)
      remount_task = mount_tasks.last

      before_delete_ids = smb_tasks.where("options ->> 'action' = 'delete'").pluck(:id)
      fail!(remount_task)

      expect(assignment.reload.status).to eq("degraded")
      # the old identity is never asked to be torn down — no delete task is
      # dispatched at all — so the consumer keeps working on its existing
      # session until a retry succeeds. Its DB status stays "rotating" (NOT
      # "revoked" — review correction), so a teardown before any retry
      # succeeds still goes through StorageCredential
      # #deprovision_before_destroy!'s ordinary guard with no special case.
      expect(smb_tasks.where("options ->> 'action' = 'delete'").where.not(id: before_delete_ids)).to be_empty
      expect(old_credential.reload.status).to eq("rotating")
    end

    it "a failed-then-retried remount eventually confirms and retires the old identity" do
      old_credential, new_credential = perform_scheme_crossing_rotation!
      create_task = smb_tasks.where("options ->> 'action' = 'create'")
                             .where("options -> 'credential' ->> 'id' = ?", new_credential.id).last
      complete!(create_task)
      failed_remount_task = mount_tasks.last
      fail!(failed_remount_task)
      expect(assignment.reload.status).to eq("degraded")

      # The next reconcile tick (drift sensor / heartbeat) re-admits a
      # "degraded" assignment via pending_reconcile and retries.
      before_ids = mount_tasks.pluck(:id)
      ::System::Storage::AssignmentReconciliationService.reconcile_assignment!(assignment)
      retry_task = mount_tasks.where.not(id: before_ids).last
      expect(retry_task).to be_present
      expect(retry_task.options["remount"]).to be true

      complete!(retry_task)

      expect(assignment.reload.mounted_credential_id).to eq(new_credential.id)
      expect(old_credential.reload.status).to eq("revoked")
    end
  end

  # Rollout-skew review — the exact scenario the gate exists for: an old
  # (pre-remount-aware) agent ignores `remount`, runs a no-op `start` on an
  # already-active unit, and reports the task complete regardless. Driven
  # through the REAL endpoint throughout, per Amendment B's own reasoning:
  # this is precisely the kind of gate a model-level spec could pass while
  # silently never firing in production.
  context "rollout-skew confirmation gate" do
    it "an old-shape completion (no mounted_credential_id at all) does not flip mounted_credential_id, retires nothing, and sets error_message" do
      old_credential, new_credential = perform_scheme_crossing_rotation!
      create_task = smb_tasks.where("options ->> 'action' = 'create'")
                             .where("options -> 'credential' ->> 'id' = ?", new_credential.id).last
      complete!(create_task)
      remount_task = mount_tasks.last

      before_delete_ids = smb_tasks.where("options ->> 'action' = 'delete'").pluck(:id)
      complete!(remount_task, result: { "ok" => true }) # the old-agent shape

      expect(assignment.reload.mounted_credential_id).not_to eq(new_credential.id)
      expect(smb_tasks.where("options ->> 'action' = 'delete'").where.not(id: before_delete_ids)).to be_empty
      expect(old_credential.reload.status).to eq("rotating")
      expect(assignment.error_message).to eq("agent did not confirm mounted credential (agent upgrade needed?)")
    end

    it "a completion confirming a DIFFERENT (mismatched) credential id does not flip or retire" do
      old_credential, new_credential = perform_scheme_crossing_rotation!
      create_task = smb_tasks.where("options ->> 'action' = 'create'")
                             .where("options -> 'credential' ->> 'id' = ?", new_credential.id).last
      complete!(create_task)
      remount_task = mount_tasks.last

      before_delete_ids = smb_tasks.where("options ->> 'action' = 'delete'").pluck(:id)
      complete!(remount_task, result: { "mounted_credential_id" => old_credential.id })

      expect(assignment.reload.mounted_credential_id).not_to eq(new_credential.id)
      expect(smb_tasks.where("options ->> 'action' = 'delete'").where.not(id: before_delete_ids)).to be_empty
      expect(old_credential.reload.status).to eq("rotating")
      expect(assignment.error_message).to eq("agent did not confirm mounted credential (agent upgrade needed?)")
    end

    it "a completion confirming the MATCHING credential id flips mounted_credential_id and retires the old identity" do
      old_credential, new_credential = perform_scheme_crossing_rotation!
      create_task = smb_tasks.where("options ->> 'action' = 'create'")
                             .where("options -> 'credential' ->> 'id' = ?", new_credential.id).last
      complete!(create_task)
      remount_task = mount_tasks.last

      before_delete_ids = smb_tasks.where("options ->> 'action' = 'delete'").pluck(:id)
      complete!(remount_task, result: { "mounted_credential_id" => new_credential.id })

      expect(assignment.reload.mounted_credential_id).to eq(new_credential.id)
      delete_task = smb_tasks.where("options ->> 'action' = 'delete'").where.not(id: before_delete_ids).last
      expect(delete_task).to be_present
      expect(old_credential.reload.status).to eq("revoked")
    end

    # remount:false + NULL mounted_credential_id + already-active unit —
    # the reviewer's own extension of the same bug to a plain first mount.
    it "an unconfirmed FIRST (non-remount) mount completion does not set mounted_credential_id" do
      assignment
      first_mount_task = mount_tasks.last
      expect(first_mount_task.options["remount"]).to be(false).or be_nil

      complete!(first_mount_task, result: { "ok" => true }) # old-agent shape

      expect(assignment.reload.mounted_credential_id).to be_nil
      expect(assignment.error_message).to eq("agent did not confirm mounted credential (agent upgrade needed?)")
    end
  end
end
