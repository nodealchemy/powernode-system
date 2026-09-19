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

  # The "true removal" case #rotate! deliberately does NOT exercise: no
  # successor exists, so #revoke! must still deprovision — this is the case
  # the username-collision guard must never swallow.
  describe "#revoke! (true removal, no successor)" do
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
end
