# frozen_string_literal: true

require "rails_helper"

# IMP-ab6e4075a007 — the SMB user task payload used to carry the plaintext
# password (and, on rotate, the new plaintext password) straight into
# System::Task#options, a plaintext jsonb column. These specs pin the fix: the
# payload carries a CredentialRef the agent resolves over the existing
# node_api credential endpoint instead.
RSpec.describe System::Storage::SmbUserManager do
  let(:account) { create(:account) }
  let(:backend_instance) { create(:system_node_instance, account: account) }
  let(:node_instance) { create(:system_node_instance, account: account) }
  let(:file_storage) do
    create(:file_storage, :smb, :node_mountable, account: account,
      configuration: {
        "mount_path" => "/mnt/test",
        "server_address" => "192.168.1.200",
        "share_name" => "storage",
        "export_host_node_instance_id" => backend_instance.id
      })
  end
  let(:assignment) do
    create(:system_storage_assignment,
      account: account,
      file_storage_id: file_storage.id,
      node_instance: node_instance,
      mount_path: "/mnt/test")
  end

  def issued_credential(username: "node-abc123", password: "s3cr3t-pw", status: "active")
    cred = create(:system_storage_credential,
      storage_assignment: assignment,
      node_instance: node_instance,
      kind: "cifs_user_pass",
      status: status)
    cred.store_in_vault("username" => username, "password" => password)
    ::System::StorageCredential.find(cred.id)
  end

  subject(:manager) { described_class.new(assignment: assignment) }

  def last_task
    ::System::Task.where(command: "storage.smb_user.apply").order(:created_at).last
  end

  describe "#provision_user!" do
    let(:credential) { issued_credential }

    it "dispatches a storage.smb_user.apply task to the storage's backend node instance" do
      manager.provision_user!(credential: credential)
      expect(last_task.operable_id).to eq(backend_instance.id)
      expect(last_task.options["action"]).to eq("create")
    end

    it "never persists a plaintext password anywhere in the payload" do
      manager.provision_user!(credential: credential)
      expect(last_task.options).not_to have_key("password")
      expect(last_task.options).not_to have_key("new_password")
      expect(last_task.options.to_s).not_to include("s3cr3t-pw")
    end

    it "carries a CredentialRef naming the EXACT credential id via the existing node_api endpoint" do
      manager.provision_user!(credential: credential)
      ref = last_task.options["credential"]
      expect(ref).to include("id" => credential.id, "kind" => "cifs_user_pass")
      expect(ref["url"]).to eq(
        "/api/v1/system/node_api/storage_assignments/#{assignment.id}/credential?credential_id=#{credential.id}"
      )
    end

    it "still carries the (non-secret) username inline" do
      manager.provision_user!(credential: credential)
      expect(last_task.options["username"]).to eq("node-abc123")
    end
  end

  describe "#deprovision_user!" do
    let(:credential) { issued_credential }

    it "dispatches a delete action with no plaintext password" do
      manager.deprovision_user!(credential: credential)
      expect(last_task.options["action"]).to eq("delete")
      expect(last_task.options).not_to have_key("password")
      expect(last_task.options.to_s).not_to include("s3cr3t-pw")
    end
  end

  describe "#rotate_user!" do
    let(:credential) { issued_credential }
    let(:new_credential) { issued_credential(password: "brand-new-pw", status: "issued") }

    it "carries a new_credential ref instead of a raw new_password" do
      manager.rotate_user!(credential: credential, new_credential: new_credential)
      expect(last_task.options["action"]).to eq("set_password")
      expect(last_task.options).not_to have_key("new_password")
      expect(last_task.options).not_to have_key("password")
      expect(last_task.options["new_credential"]).to include("id" => new_credential.id)
      expect(last_task.options.to_s).not_to include("brand-new-pw")
    end

    it "points credential and new_credential at two DIFFERENT credential ids" do
      manager.rotate_user!(credential: credential, new_credential: new_credential)
      old_ref = last_task.options["credential"]
      new_ref = last_task.options["new_credential"]
      expect(old_ref["id"]).to eq(credential.id)
      expect(new_ref["id"]).to eq(new_credential.id)
      expect(old_ref["url"]).to end_with("credential_id=#{credential.id}")
      expect(new_ref["url"]).to end_with("credential_id=#{new_credential.id}")
    end
  end

  describe "#provision_user! without an assignment" do
    subject(:manager) { described_class.new(storage: file_storage) }

    it "refuses to build a credential ref it cannot make resolvable" do
      expect { manager.provision_user!(credential: issued_credential) }
        .to raise_error(/requires an assignment/)
    end
  end
end
