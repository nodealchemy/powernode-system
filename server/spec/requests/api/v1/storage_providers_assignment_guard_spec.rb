# frozen_string_literal: true

require "rails_helper"

# The storage delete endpoint is core (DELETE /api/v1/storage/:id); the guard
# it has to honour is registered by this extension on the core model. This is
# the end-to-end shape: the endpoint refuses, names the count, and the
# assignment still resolves its storage afterwards.
RSpec.describe "DELETE /api/v1/storage/:id with storage assignments", type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:headers) { auth_headers_for(user) }
  let!(:storage) { create(:file_storage, :nfs, :node_mountable, account: account) }

  before do
    allow_any_instance_of(User).to receive(:has_permission?).and_return(true)
  end

  context "when a storage assignment references the storage" do
    let!(:assignment) do
      create(:system_storage_assignment, account: account, file_storage_id: storage.id)
    end

    it "refuses with a 422 naming the assignment count and orphans nothing" do
      expect {
        delete "/api/v1/storage/#{storage.id}", headers: headers, as: :json
      }.not_to change { account.file_storages.count }

      expect_error_response(
        "Cannot delete storage with 1 storage assignment. Remove the assignments first.", 422
      )
      expect(System::StorageAssignment.find(assignment.id).file_storage).to eq(storage)
    end
  end

  context "when no storage assignment references the storage" do
    it "deletes the storage" do
      expect {
        delete "/api/v1/storage/#{storage.id}", headers: headers, as: :json
      }.to change { account.file_storages.count }.by(-1)

      expect_success_response
    end
  end
end
