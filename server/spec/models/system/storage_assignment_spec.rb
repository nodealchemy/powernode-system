# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::StorageAssignment, type: :model do
  let(:account) { create(:account) }
  let(:node_instance) { create(:system_node_instance, account: account) }
  let(:file_storage) { create(:file_storage, :nfs, :node_mountable, account: account) }

  subject(:assignment) do
    build(
      :system_storage_assignment,
      account: account,
      file_storage_id: file_storage.id,
      node_instance: node_instance
    )
  end

  describe "validations" do
    it "is valid with the default factory" do
      expect(assignment).to be_valid
    end

    it "requires a file_storage_id" do
      assignment.file_storage_id = nil
      expect(assignment).not_to be_valid
      expect(assignment.errors[:file_storage_id]).to be_present
    end

    it "requires the referenced FileManagement::Storage to exist" do
      assignment.file_storage_id = SecureRandom.uuid
      expect(assignment).not_to be_valid
      expect(assignment.errors[:file_storage_id].join).to include("must reference an existing")
    end

    it "rejects a storage that isn't node_mount_capable" do
      file_storage.update!(node_mount_capable: false)
      assignment.instance_variable_set(:@file_storage, nil)
      expect(assignment).not_to be_valid
      expect(assignment.errors[:file_storage_id].join).to include("node_mount_capable")
    end

    it "requires mount_path to be an absolute path" do
      assignment.mount_path = "relative/path"
      expect(assignment).not_to be_valid
      expect(assignment.errors[:mount_path].join).to include("absolute")
    end

    it "validates encryption_mode inclusion" do
      assignment.encryption_mode = "bogus"
      expect(assignment).not_to be_valid
      expect(assignment.errors[:encryption_mode]).to be_present
    end

    it "rejects luks encryption for object-storage providers" do
      object_storage = create(:file_storage, :s3, :node_mountable, account: account)
      assignment.file_storage_id = object_storage.id
      assignment.instance_variable_set(:@file_storage, nil)
      assignment.encryption_mode = "luks"
      expect(assignment).not_to be_valid
      expect(assignment.errors[:encryption_mode].join).to include("requires block storage")
    end

    it "rejects client_side_aes encryption for NFS providers" do
      assignment.encryption_mode = "client_side_aes"
      expect(assignment).not_to be_valid
      expect(assignment.errors[:encryption_mode].join).to include("object storage")
    end
  end

  describe "#derived_uid" do
    it "is deterministic for the same node_instance_id" do
      assignment.save!
      first = assignment.derived_uid
      assignment.reload
      expect(assignment.derived_uid).to eq(first)
    end

    it "falls within the 100k-slot range" do
      assignment.save!
      expect(assignment.derived_uid).to be >= 100_000
      expect(assignment.derived_uid).to be < 200_000
    end
  end

  describe "#effective_encryption_mode" do
    it "returns the literal value when not 'inherit'" do
      assignment.encryption_mode = "none"
      expect(assignment.effective_encryption_mode).to eq("none")
    end

    it "resolves 'inherit' to fscrypt for NFS" do
      assignment.encryption_mode = "inherit"
      expect(assignment.effective_encryption_mode).to eq("fscrypt")
    end

    it "resolves 'inherit' to client_side_aes for S3" do
      object_storage = create(:file_storage, :s3, :node_mountable, account: account)
      assignment.file_storage_id = object_storage.id
      assignment.instance_variable_set(:@file_storage, nil)
      assignment.encryption_mode = "inherit"
      expect(assignment.effective_encryption_mode).to eq("client_side_aes")
    end
  end

  describe "scopes" do
    # update_columns bypasses the after_commit :trigger_reconcile hook so we
    # can set deterministic statuses for scope assertions without the
    # reconciler bumping them to "failed" mid-test.
    let!(:pending_assignment) do
      a = create(:system_storage_assignment, account: account, file_storage_id: file_storage.id,
        node_instance: create(:system_node_instance, account: account))
      a.update_columns(status: "pending")
      a
    end
    let!(:mounted_assignment) do
      a = create(:system_storage_assignment, account: account, file_storage_id: file_storage.id,
        node_instance: create(:system_node_instance, account: account))
      a.update_columns(status: "mounted")
      a
    end

    it ".pending_reconcile only returns enabled non-mounted rows" do
      expect(described_class.pending_reconcile).to include(pending_assignment)
      expect(described_class.pending_reconcile).not_to include(mounted_assignment)
    end

    it ".mounted returns only mounted rows" do
      expect(described_class.mounted).to include(mounted_assignment)
      expect(described_class.mounted).not_to include(pending_assignment)
    end
  end
end
