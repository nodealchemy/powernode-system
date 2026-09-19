# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::StorageCredential, type: :model do
  let(:account) { create(:account) }
  let(:node_instance) { create(:system_node_instance, account: account) }
  let(:file_storage) { create(:file_storage, :nfs, :node_mountable, account: account) }
  let(:assignment) do
    create(:system_storage_assignment,
      account: account, file_storage_id: file_storage.id, node_instance: node_instance)
  end

  subject(:credential) do
    described_class.new(
      storage_assignment: assignment,
      node_instance: node_instance,
      kind: "peer_ip_acl",
      status: "issued",
      metadata: { peer_ip: "fd00::1" }
    )
  end

  it "is valid with peer_ip_acl kind" do
    expect(credential).to be_valid
  end

  it "rejects unknown kinds" do
    credential.kind = "bogus"
    expect(credential).not_to be_valid
  end

  it "rejects kerberos kind (SDWAN-as-trust-anchor, no KDC in v1)" do
    credential.kind = "kerberos"
    expect(credential).not_to be_valid
  end

  it "delegates account_id to the storage_assignment" do
    expect(credential.account_id).to eq(assignment.account_id)
  end

  describe "#expired?" do
    it "is false when expires_at is nil (no expiry — peer_ip_acl)" do
      credential.expires_at = nil
      expect(credential.expired?).to be false
    end

    it "is true once expires_at has passed" do
      credential.expires_at = 1.minute.ago
      expect(credential.expired?).to be true
    end
  end

  describe "#needs_rotation?" do
    it "is true within the rotation window" do
      credential.expires_at = 12.hours.from_now
      expect(credential.needs_rotation?).to be true
    end

    it "is false outside the rotation window" do
      credential.expires_at = 5.days.from_now
      expect(credential.needs_rotation?).to be false
    end
  end

  describe ".active scope" do
    before { credential.save! }

    it "includes issued + active" do
      expect(described_class.active).to include(credential)
      credential.update!(status: "active")
      expect(described_class.active).to include(credential)
    end

    it "excludes revoked + expired" do
      credential.update!(status: "revoked")
      expect(described_class.active).not_to include(credential)
    end
  end

  describe "vault credential type" do
    it "uses the 'storage_node_access' namespace" do
      expect(described_class.vault_credential_type).to eq("storage_node_access")
    end
  end

  # IMP-e88b38770d13 — destroying a StorageCredential (directly, or via
  # StorageAssignment's own dependent: :destroy, or via NodeInstance
  # #cascade_destroy_dependents!) used to just delete the row: no
  # samba-tool deprovision, no NFS peer ACL revoke. The backend kept
  # working credentials for an assignment/instance the platform believes
  # no longer exists.
  describe "#before_destroy deprovisioning" do
    context "for NFS" do
      # The outer file_storage let's :nfs trait has no
      # export_host_node_instance_id, so NfsExportManager#dispatch_task
      # would raise "No backend node instance configured" before ever
      # reaching the assertion below — override with one that has it,
      # exactly like credential_issuer_spec.rb's own NFS fixture.
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

      # A surviving sibling on the SAME storage — review round 1: a
      # single-entry "revoke" dispatch would have OVERWRITTEN the exports
      # file with just the destroyed peer (agent's ApplyExports only
      # deletes the file on a zero-entry revoke; otherwise it replaces the
      # whole file with the given entries), which would have cut this
      # survivor off. The fix rebuilds the whole file from live DB state
      # instead — asserted below by content, not just task count.
      let(:survivor_instance) { create(:system_node_instance, account: account) }
      let!(:survivor_assignment) do
        create(:system_storage_assignment,
          account: account, file_storage_id: file_storage.id,
          node_instance: survivor_instance, mount_path: "/mnt/survivor")
      end
      let!(:survivor_credential) do
        described_class.create!(
          storage_assignment: survivor_assignment, node_instance: survivor_instance,
          kind: "peer_ip_acl", status: "issued", metadata: { peer_ip: "fd00::2" }
        )
      end

      def exports_tasks
        System::Task.where(command: "storage.exports.apply").order(:created_at)
      end

      it "rebuilds the whole exports file on destroy, excluding the destroyed peer and including the survivor" do
        credential.save!
        before_ids = exports_tasks.pluck(:id)

        credential.destroy

        new_tasks = exports_tasks.where.not(id: before_ids)
        expect(new_tasks.count).to eq(1)
        task = new_tasks.first
        expect(task.options["action"]).to eq("reconcile")
        peer_ips = task.options["entries"].map { |e| e["peer_ip"] }
        expect(peer_ips).not_to include("fd00::1")
        expect(peer_ips).to include("fd00::2")
        expect(credential.destroyed?).to be true
      end

      it "does not dispatch anything for an already-revoked credential" do
        credential.save!
        credential.update!(status: "revoked")
        before_count = exports_tasks.count

        credential.destroy

        expect(exports_tasks.count).to eq(before_count)
      end
    end

    context "for SMB" do
      let(:backend_instance) { create(:system_node_instance, account: account) }
      let(:smb_storage) do
        create(:file_storage, :smb, :node_mountable, account: account,
          configuration: {
            "mount_path" => "/mnt/smb-destroy",
            "server_address" => "192.168.1.220",
            "share_name" => "destroy-share",
            "export_host_node_instance_id" => backend_instance.id
          })
      end
      let(:smb_assignment) do
        create(:system_storage_assignment,
          account: account, file_storage_id: smb_storage.id,
          node_instance: node_instance, mount_path: "/mnt/smb-destroy")
      end

      def smb_tasks
        System::Task.where(command: "storage.smb_user.apply").order(:created_at)
      end

      # StorageAssignment#after_commit auto-issues its OWN credential for
      # this same deterministic username on create — revoke it first so
      # "the last live credential" assertions below are about the ONE
      # credential this test actually manages, not an auto-issued sibling.
      before { smb_assignment.storage_credentials.update_all(status: "revoked") }

      it "dispatches a delete when the last live SMB credential is destroyed directly" do
        credential = ::System::Storage::CredentialIssuer.new(assignment: smb_assignment).issue!
        before_ids = smb_tasks.pluck(:id)

        credential.destroy

        new_tasks = smb_tasks.where.not(id: before_ids)
        expect(new_tasks.count).to eq(1)
        expect(new_tasks.first.options["action"]).to eq("delete")
        expect(credential.destroyed?).to be true
      end

      it "destroying the whole assignment (multiple live siblings) dispatches exactly one delete" do
        # Simulates a rotation mid-flight: two live rows sharing the SAME
        # deterministic username, neither linked as an explicit successor.
        issuer = ::System::Storage::CredentialIssuer.new(assignment: smb_assignment)
        issuer.issue!
        second = issuer.send(:issue_credential_row!)
        second.activate!
        before_ids = smb_tasks.pluck(:id)

        smb_assignment.destroy

        new_tasks = smb_tasks.where.not(id: before_ids)
        expect(new_tasks.count).to eq(1)
        expect(new_tasks.first.options["action"]).to eq("delete")
        expect(::System::StorageCredential.where(storage_assignment_id: smb_assignment.id)).to be_empty
      end

      it "does not dispatch for an already-revoked credential" do
        credential = ::System::Storage::CredentialIssuer.new(assignment: smb_assignment).issue!
        credential.update!(status: "revoked")
        before_count = smb_tasks.count

        credential.destroy

        expect(smb_tasks.count).to eq(before_count)
      end

      it "never blocks the destroy even if deprovisioning fails, and logs it" do
        credential = ::System::Storage::CredentialIssuer.new(assignment: smb_assignment).issue!
        allow(::System::Storage::SmbUserManager).to receive(:new).and_raise(StandardError, "backend unreachable")
        expect(Rails.logger).to receive(:error).with(/deprovision-on-destroy failed.*backend unreachable/)

        expect { credential.destroy! }.not_to raise_error
        expect(::System::StorageCredential.where(id: credential.id)).not_to exist
      end
    end
  end
end
