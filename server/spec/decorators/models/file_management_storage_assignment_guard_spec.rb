# frozen_string_literal: true

require "rails_helper"

# system_storage_assignments.file_storage_id carries no foreign key and
# System::StorageAssignment#file_storage is a hand-written lookup, so nothing
# in the database or on the core model ties a FileManagement::Storage to the
# assignments that mount it. The decorator refuses the destroy instead; these
# examples pin both arms at the model, which is the layer every destroy path
# (the storage controller, Account's dependent: :destroy) goes through.
RSpec.describe "FileManagement::Storage storage-assignment destroy guard", type: :model do
  let(:account) { create(:account) }
  let(:storage) { create(:file_storage, :nfs, :node_mountable, account: account) }

  def assign!(**attrs)
    create(:system_storage_assignment, account: account, file_storage_id: storage.id, **attrs)
  end

  context "when storage assignments reference the storage" do
    let!(:assignment) { assign! }

    it "refuses the destroy and leaves the assignment resolvable" do
      expect(storage.destroy).to be(false)

      expect(FileManagement::Storage.exists?(storage.id)).to be(true)
      expect(System::StorageAssignment.find(assignment.id).file_storage).to eq(storage)
    end

    it "names the number of assignments in the error" do
      assign!(mount_path: "/mnt/other")
      storage.destroy

      expect(storage.errors[:base]).to eq(
        [ "Cannot delete storage with 2 storage assignments. Remove the assignments first." ]
      )
    end

    it "uses the singular for one assignment" do
      storage.destroy

      expect(storage.errors[:base]).to eq(
        [ "Cannot delete storage with 1 storage assignment. Remove the assignments first." ]
      )
    end

    it "counts a disabled assignment — the row and its credentials would still be orphaned" do
      assignment.update_columns(enabled: false, status: "disabled")

      expect(storage.destroy).to be(false)
      expect(storage.errors[:base].join).to include("1 storage assignment")
    end

    it "raises from destroy! rather than deleting" do
      expect { storage.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
      expect(FileManagement::Storage.exists?(storage.id)).to be(true)
    end

    it "blocks a destroy reached through the account's association" do
      expect { account.file_storages.destroy_all }.to raise_error(ActiveRecord::RecordNotDestroyed)

      expect(FileManagement::Storage.exists?(storage.id)).to be(true)
      expect(System::StorageAssignment.find(assignment.id).file_storage).to eq(storage)
    end

    # Characterisation, not a red-first example: Account's own
    # restrict_with_error on system_storage_assignments already refused this
    # before the guard existed. Pinned so the cascade stays a clean `false`.
    it "leaves Account#destroy a clean refusal" do
      expect(account.destroy).to be(false)

      expect(FileManagement::Storage.exists?(storage.id)).to be(true)
      expect(System::StorageAssignment.exists?(assignment.id)).to be(true)
    end

    it "allows the destroy once the assignment is gone" do
      assignment.destroy!

      expect(storage.destroy).to be_truthy
      expect(FileManagement::Storage.exists?(storage.id)).to be(false)
    end
  end

  context "when no storage assignment references the storage" do
    it "destroys the storage" do
      expect(storage.destroy).to be_truthy
      expect(FileManagement::Storage.exists?(storage.id)).to be(false)
    end

    it "ignores assignments that reference a different storage" do
      other = create(:file_storage, :nfs, :node_mountable, account: account)
      create(:system_storage_assignment, account: account, file_storage_id: other.id)

      expect(storage.destroy).to be_truthy
      expect(FileManagement::Storage.exists?(other.id)).to be(true)
    end
  end
end
