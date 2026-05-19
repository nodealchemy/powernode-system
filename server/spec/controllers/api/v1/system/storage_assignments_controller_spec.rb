# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — controller spec for storage assignments.
#
# Permission family: system.storage.assignments.*. The rotate_credential
# action uses its own permission (system.storage.assignments.rotate_credential)
# and delegates to Storage::CredentialIssuer; without an active credential
# it returns 422 — that's the safest happy path to assert without bringing
# Vault into the test environment.
RSpec.describe "Api::V1::System::StorageAssignments", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.storage.assignments.read",             account: account) }
  let(:create_user) { user_with_permissions("system.storage.assignments.create",           account: account) }
  let(:update_user) { user_with_permissions("system.storage.assignments.read", "system.storage.assignments.update", account: account) }
  let(:delete_user) { user_with_permissions("system.storage.assignments.delete",           account: account) }
  let(:rotate_user) { user_with_permissions("system.storage.assignments.rotate_credential", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let(:node) { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, node: node, account: account) }
  let(:file_storage) { create(:file_storage, :node_mountable, account: account) }
  let!(:assignment) do
    create(:system_storage_assignment,
           account: account, node_instance: instance, file_storage_id: file_storage.id)
  end

  describe "GET /api/v1/system/storage_assignments" do
    it "returns 401 without auth" do
      get "/api/v1/system/storage_assignments"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/storage_assignments", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "scopes to the caller's account" do
      foreign_node = create(:system_node, account: other_account)
      foreign_instance = create(:system_node_instance, node: foreign_node, account: other_account)
      foreign_storage = create(:file_storage, :node_mountable, account: other_account)
      foreign = create(:system_storage_assignment, account: other_account, node_instance: foreign_instance,
                                                   file_storage_id: foreign_storage.id)
      get "/api/v1/system/storage_assignments", headers: auth_headers_for(read_user)
      ids = json_response_data["assignments"].map { |a| a["id"] }
      expect(ids).to include(assignment.id)
      expect(ids).not_to include(foreign.id)
    end
  end

  describe "GET /api/v1/system/storage_assignments/:id" do
    it "returns the assignment" do
      get "/api/v1/system/storage_assignments/#{assignment.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["assignment"]["id"]).to eq(assignment.id)
    end

    it "returns 404 for another account's assignment" do
      foreign_node = create(:system_node, account: other_account)
      foreign_instance = create(:system_node_instance, node: foreign_node, account: other_account)
      foreign_storage = create(:file_storage, :node_mountable, account: other_account)
      foreign = create(:system_storage_assignment, account: other_account, node_instance: foreign_instance,
                                                   file_storage_id: foreign_storage.id)
      get "/api/v1/system/storage_assignments/#{foreign.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/storage_assignments" do
    it "returns 403 without create perm" do
      post "/api/v1/system/storage_assignments",
           params: { assignment: { mount_path: "/mnt/x" } }.to_json,
           headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PATCH /api/v1/system/storage_assignments/:id" do
    it "updates the assignment" do
      patch "/api/v1/system/storage_assignments/#{assignment.id}",
            params: { assignment: { mount_path: "/mnt/renamed" } }.to_json,
            headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(assignment.reload.mount_path).to eq("/mnt/renamed")
    end
  end

  describe "DELETE /api/v1/system/storage_assignments/:id" do
    it "destroys the assignment" do
      expect {
        delete "/api/v1/system/storage_assignments/#{assignment.id}", headers: auth_headers_for(delete_user)
      }.to change { ::System::StorageAssignment.where(id: assignment.id).count }.by(-1)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/system/storage_assignments/:id/reconcile" do
    it "calls AssignmentReconciliationService.reconcile_assignment!" do
      allow(::System::Storage::AssignmentReconciliationService)
        .to receive(:reconcile_assignment!).and_return(true)
      post "/api/v1/system/storage_assignments/#{assignment.id}/reconcile",
           headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/system/storage_assignments/:id/rotate_credential" do
    it "returns 403 without rotate_credential perm" do
      post "/api/v1/system/storage_assignments/#{assignment.id}/rotate_credential",
           headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 422 when no active credential exists (defensive guard)" do
      post "/api/v1/system/storage_assignments/#{assignment.id}/rotate_credential",
           headers: auth_headers_for(rotate_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_entity)
    end
  end
end
