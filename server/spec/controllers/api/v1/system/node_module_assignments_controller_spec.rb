# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — controller spec for node_module_assignments.
#
# Tiny operator surface: GET :id (show) + POST :id/enable + POST :id/disable.
# Permissions: system.modules.read for show, system.modules.update for
# enable/disable. Account scoping joins through the node (assignments
# don't have account_id directly).
RSpec.describe "Api::V1::System::NodeModuleAssignments", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.modules.read",   account: account) }
  let(:update_user) { user_with_permissions("system.modules.update", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:node_module) { create(:system_node_module, account: account, node_platform: platform, category: category) }
  let(:node) { create(:system_node, account: account) }
  let!(:assignment) do
    ::System::NodeModuleAssignment.create!(node: node, node_module: node_module, enabled: true, priority: 50)
  end

  describe "GET /api/v1/system/node_module_assignments/:id" do
    it "returns 401 without auth" do
      get "/api/v1/system/node_module_assignments/#{assignment.id}"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/node_module_assignments/#{assignment.id}",
          headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns the assignment" do
      get "/api/v1/system/node_module_assignments/#{assignment.id}",
          headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["node_module_assignment"]["id"]).to eq(assignment.id)
    end

    it "returns 404 when the assignment's node belongs to another account" do
      foreign_platform = create(:system_node_platform, account: other_account)
      foreign_category = create(:system_node_module_category, account: other_account)
      foreign_module = create(:system_node_module, account: other_account,
                                                    node_platform: foreign_platform, category: foreign_category)
      foreign_node = create(:system_node, account: other_account)
      foreign_assignment = ::System::NodeModuleAssignment.create!(
        node: foreign_node, node_module: foreign_module, enabled: true, priority: 50
      )

      get "/api/v1/system/node_module_assignments/#{foreign_assignment.id}",
          headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/node_module_assignments/:id/enable" do
    it "returns 403 without update perm" do
      assignment.update!(enabled: false)
      post "/api/v1/system/node_module_assignments/#{assignment.id}/enable",
           headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "flips enabled to true (idempotent)" do
      assignment.update!(enabled: false)
      post "/api/v1/system/node_module_assignments/#{assignment.id}/enable",
           headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(assignment.reload.enabled).to be(true)
    end
  end

  describe "POST /api/v1/system/node_module_assignments/:id/disable" do
    it "flips enabled to false (idempotent)" do
      post "/api/v1/system/node_module_assignments/#{assignment.id}/disable",
           headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(assignment.reload.enabled).to be(false)
    end
  end
end
