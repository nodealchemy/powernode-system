# frozen_string_literal: true

require "rails_helper"

# IMP-ab6e4075a007 — System::Storage::SmbUserManager points the agent at this
# endpoint (via a CredentialRef naming an EXACT credential id) instead of
# embedding the password in the task payload. Review round 1 rejected a
# storage-configuration-derived grant (any node the storage's current config
# names as its backend can read ANY credential on the assignment) as a
# confused-deputy / stale-config hole, and found it had also widened
# set_assignment's authz to update_status and encryption_key, which have
# nothing to do with SMB provisioning. This spec pins the replacement: a
# LIVE, per-task grant, scoped to exactly the credential id a live task
# names, and #credential is the ONLY action with any non-owning-client path.
RSpec.describe "Api::V1::System::NodeApi::StorageAssignments#credential", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }

  def mtls_headers_for(instance, not_before: 1.hour.ago, not_after: 90.days.from_now)
    System::NodeCertificate.create!(
      node_instance: instance,
      serial: SecureRandom.hex(16),
      subject: "CN=#{instance.id}",
      not_before: not_before,
      not_after: not_after,
      issuer_subject: "CN=Powernode Internal CA"
    )
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) }
  end

  let(:client_instance)  { create(:system_node_instance, account: account) }
  let(:backend_instance) { create(:system_node_instance, account: account) }
  let(:other_instance)   { create(:system_node_instance, account: account) }

  let(:file_storage) do
    create(:file_storage, :smb, :node_mountable, account: account,
      configuration: {
        "mount_path" => "/mnt/test",
        "server_address" => "192.168.1.200",
        "share_name" => "storage",
        "export_host_node_instance_id" => backend_instance.id
      })
  end
  let!(:assignment) do
    create(:system_storage_assignment,
      account: account, node_instance: client_instance,
      file_storage_id: file_storage.id, mount_path: "/mnt/test")
  end
  let!(:credential) do
    cred = create(:system_storage_credential,
      storage_assignment: assignment, node_instance: client_instance,
      kind: "cifs_user_pass", status: "active")
    cred.store_in_vault("username" => "node-abc123", "password" => "s3cr3t-pw")
    cred
  end

  def live_smb_task!(operable:, credential_id:, status: "pending", account: self.account, key: "credential")
    create(:system_task,
      account: account,
      operable: operable,
      command: "storage.smb_user.apply",
      status: status,
      options: { key => { "id" => credential_id, "kind" => "cifs_user_pass", "url" => "irrelevant" } })
  end

  # --- Owning client: unchanged behavior, no credential_id needed --------

  it "serves the active credential to the assignment's own client node_instance with no credential_id" do
    get "/api/v1/system/node_api/storage_assignments/#{assignment.id}/credential",
        headers: mtls_headers_for(client_instance)
    expect(response).to have_http_status(:ok)
    expect(json_response_data["password"]).to eq("s3cr3t-pw")
  end

  # --- SMB backend: only via a live, matching, per-task grant -------------

  it "refuses the backend with no live storage.smb_user.apply task at all" do
    get "/api/v1/system/node_api/storage_assignments/#{assignment.id}/credential",
        params: { credential_id: credential.id }, headers: mtls_headers_for(backend_instance)
    expect(response).to have_http_status(:not_found)
  end

  it "serves the named credential to the backend once a matching pending task exists" do
    live_smb_task!(operable: backend_instance, credential_id: credential.id)
    get "/api/v1/system/node_api/storage_assignments/#{assignment.id}/credential",
        params: { credential_id: credential.id }, headers: mtls_headers_for(backend_instance)
    expect(response).to have_http_status(:ok)
    expect(json_response_data["password"]).to eq("s3cr3t-pw")
  end

  it "serves the credential when the live task names it as new_credential (rotate)" do
    live_smb_task!(operable: backend_instance, credential_id: credential.id, key: "new_credential")
    get "/api/v1/system/node_api/storage_assignments/#{assignment.id}/credential",
        params: { credential_id: credential.id }, headers: mtls_headers_for(backend_instance)
    expect(response).to have_http_status(:ok)
  end

  it "refuses a credential_id the live task does not name" do
    other_credential = create(:system_storage_credential,
      storage_assignment: assignment, node_instance: client_instance,
      kind: "cifs_user_pass", status: "active")
    live_smb_task!(operable: backend_instance, credential_id: other_credential.id)

    get "/api/v1/system/node_api/storage_assignments/#{assignment.id}/credential",
        params: { credential_id: credential.id }, headers: mtls_headers_for(backend_instance)
    expect(response).to have_http_status(:not_found)
  end

  it "refuses without a credential_id param even with a live matching task" do
    live_smb_task!(operable: backend_instance, credential_id: credential.id)
    get "/api/v1/system/node_api/storage_assignments/#{assignment.id}/credential",
        headers: mtls_headers_for(backend_instance)
    expect(response).to have_http_status(:not_found)
  end

  it "refuses once the task has left pending/running (backend after gateway reconfiguration)" do
    task = live_smb_task!(operable: backend_instance, credential_id: credential.id, status: "running")
    task.update!(status: "complete", completed_at: Time.current)

    get "/api/v1/system/node_api/storage_assignments/#{assignment.id}/credential",
        params: { credential_id: credential.id }, headers: mtls_headers_for(backend_instance)
    expect(response).to have_http_status(:not_found)
  end

  it "refuses a task belonging to a different node instance" do
    live_smb_task!(operable: other_instance, credential_id: credential.id)
    get "/api/v1/system/node_api/storage_assignments/#{assignment.id}/credential",
        params: { credential_id: credential.id }, headers: mtls_headers_for(backend_instance)
    expect(response).to have_http_status(:not_found)
  end

  it "refuses a cross-account requester even with a live task naming the credential" do
    cross_account_instance = create(:system_node_instance, account: other_account)
    # A task cannot legitimately be minted cross-account (account_id is the
    # assignment's own account), but assert the controller's OWN account check
    # holds even if a row like this existed.
    task = live_smb_task!(operable: cross_account_instance, credential_id: credential.id, account: other_account)

    get "/api/v1/system/node_api/storage_assignments/#{assignment.id}/credential",
        params: { credential_id: credential.id }, headers: mtls_headers_for(cross_account_instance)
    expect(response).to have_http_status(:not_found)
    expect(task.account_id).to eq(other_account.id)
  end

  it "does not extend the same trust to an NFS assignment's export host" do
    nfs_storage = create(:file_storage, :nfs, :node_mountable, account: account,
      configuration: {
        "export_path" => "/srv/exports/test",
        "mount_path" => "/srv/exports/test",
        "share_path" => "/srv/exports/test",
        "server_address" => "127.0.0.1",
        "export_host_node_instance_id" => backend_instance.id
      })
    nfs_client = create(:system_node_instance, account: account)
    nfs_assignment = create(:system_storage_assignment,
      account: account, node_instance: nfs_client,
      file_storage_id: nfs_storage.id, mount_path: "/mnt/nfs-test")
    nfs_credential = create(:system_storage_credential,
      storage_assignment: nfs_assignment, node_instance: nfs_client,
      kind: "peer_ip_acl", status: "active")

    get "/api/v1/system/node_api/storage_assignments/#{nfs_assignment.id}/credential",
        params: { credential_id: nfs_credential.id }, headers: mtls_headers_for(backend_instance)
    expect(response).to have_http_status(:not_found)
  end

  # --- The rest of the controller stays owning-client-only ----------------

  describe "GET .../encryption_key" do
    it "refuses the SMB backend even with a live matching credential task AND a real active key" do
      # A real, fetchable key must exist so a 404 here can only mean "the
      # backend is not authorized" — not "there happens to be nothing to
      # return", which would pass whether or not the authz check works.
      key = ::System::MountEncryptionKey.create!(
        storage_assignment: assignment, algorithm: "fscrypt-v2"
      )
      key.store_in_vault("key_material" => Base64.strict_encode64("super-secret-key-material"))
      live_smb_task!(operable: backend_instance, credential_id: credential.id)

      get "/api/v1/system/node_api/storage_assignments/#{assignment.id}/encryption_key",
          headers: mtls_headers_for(backend_instance)
      expect(response).to have_http_status(:not_found)
    end

    it "still serves the key to the owning client" do
      key = ::System::MountEncryptionKey.create!(
        storage_assignment: assignment, algorithm: "fscrypt-v2"
      )
      key.store_in_vault("key_material" => Base64.strict_encode64("super-secret-key-material"))

      get "/api/v1/system/node_api/storage_assignments/#{assignment.id}/encryption_key",
          headers: mtls_headers_for(client_instance)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST .../status" do
    it "refuses the SMB backend even with a live matching credential task" do
      live_smb_task!(operable: backend_instance, credential_id: credential.id)
      post "/api/v1/system/node_api/storage_assignments/#{assignment.id}/status",
           params: { status: "mounted" }, headers: mtls_headers_for(backend_instance)
      expect(response).to have_http_status(:not_found)
    end
  end

  # IMP-9045875d3cb8 — end-to-end ordering proof, through the REAL
  # System::Storage::CredentialIssuer#rotate! (not the live_smb_task! stub):
  # the credential the agent's set_password task actually needs
  # (new_credential) must still be fetchable to the backend AFTER #rotate!
  # — including its own synchronous revoke of the OLD credential — has fully
  # returned.
  describe "rotate! ordering" do
    # A credential's OWN vault material is never re-readable off the SAME
    # in-memory object after a second #store_in_vault call — #store_in_vault
    # only nils @vault_credentials, which leaves the ivar DEFINED (just nil),
    # so #vault_credentials's `return @vault_credentials if defined?(...)`
    # short-circuits to that nil forever after. Every other caller in this
    # codebase works around it by re-fetching via Model.find(id) rather than
    # reusing the object (see CredentialIssuer#issue_credential_row!'s own
    # comment) — do the same here rather than rediscovering it as a failure.
    def rotate_credential_for(client_instance)
      short_id = client_instance.id.to_s.delete("-").first(12)
      credential.store_in_vault("username" => "node-#{short_id}", "password" => "s3cr3t-pw")
      ::System::StorageCredential.find(credential.id)
    end

    it "still serves the new credential to the backend after the old one is revoked" do
      old_credential = rotate_credential_for(client_instance)

      new_cred = ::System::Storage::CredentialIssuer.new(assignment: assignment).rotate!(old_credential)

      expect(old_credential.reload.status).to eq("revoked")

      get "/api/v1/system/node_api/storage_assignments/#{assignment.id}/credential",
          params: { credential_id: new_cred.id }, headers: mtls_headers_for(backend_instance)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["password"]).to eq(new_cred.vault_credentials["password"])
    end

    # IMP-eb6a3c299f4b increment 3 review — this used to assert rotation
    # NEVER queues a delete, full stop. That was only ever true because,
    # pre-increment-2, a rotation's new credential ALWAYS shared the
    # outgoing one's username — deleting it would have deleted the very
    # user the new credential needs (the original IMP-9045875d3cb8 bug).
    # #rotate_credential_for forces `credential` onto the OLD-SCHEME
    # "node-<12hex>" username, while #rotate! issues its successor through
    # the REAL (increment-2) derivation — the two genuinely differ here, so
    # this is a scheme-crossing rotation, and increment 3 correctly
    # provisions the new username and deletes the OLD one (nothing else in
    # this spec's fixtures needs it). The actual invariant this endpoint's
    # spec exists to protect — never touching the NEW credential's own
    # username — is asserted directly below instead.
    it "deletes only the OLD username after a scheme-crossing rotation, never the new one" do
      old_credential = rotate_credential_for(client_instance)
      old_username = old_credential.vault_credentials["username"]

      new_cred = ::System::Storage::CredentialIssuer.new(assignment: assignment).rotate!(old_credential)
      new_username = new_cred.vault_credentials["username"]
      expect(new_username).not_to eq(old_username) # sanity — this really is a scheme-crossing rotation

      tasks = ::System::Task.where(command: "storage.smb_user.apply").order(:created_at)
      expect(tasks.where("options ->> 'action' = 'set_password'")).to be_empty

      delete_task = tasks.where("options ->> 'action' = 'delete'").last
      expect(delete_task).to be_present
      expect(delete_task.options["username"]).to eq(old_username)
      expect(delete_task.options["username"]).not_to eq(new_username)
    end

    # The common case going forward (both usernames derived for real, no
    # forced old-scheme override): a rotation of an already-current-scheme
    # credential still uses the cheaper single set_password dispatch and
    # never queues a delete — the original IMP-9045875d3cb8 invariant,
    # unchanged by increment 3.
    it "never queues a delete task when the rotation stays on the same (current-scheme) username" do
      # The `credential` let! is deliberately forced onto a hardcoded
      # "node-abc123" username for the OTHER specs in this file — it is
      # NOT what the real provider would derive, so it can't stand in for
      # a same-scheme rotation. Revoke it and issue a REAL credential (its
      # username genuinely derived, unforced) instead, so rotating it is
      # actually a same-scheme rotation.
      credential.update_columns(status: "revoked")
      real_credential = ::System::Storage::CredentialIssuer.new(assignment: assignment).issue!
      before_ids = ::System::Task.where(command: "storage.smb_user.apply").pluck(:id)

      new_cred = ::System::Storage::CredentialIssuer.new(assignment: assignment).rotate!(real_credential)

      tasks = ::System::Task.where(command: "storage.smb_user.apply").where.not(id: before_ids).order(:created_at)
      expect(tasks.where("options ->> 'action' = 'delete'")).to be_empty
      expect(tasks.where("options ->> 'action' = 'set_password'")).not_to be_empty
      expect(new_cred.vault_credentials["username"]).to eq(real_credential.reload.vault_credentials["username"])
    end
  end
end
