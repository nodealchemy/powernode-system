# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator API — Node Module Assignments", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { user_with_permissions("system.modules.read", "system.modules.update", account: account) }
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  let(:node) { create(:system_node, account: account) }
  let(:node_module) { create(:system_node_module, account: account) }
  let(:assignment) { create(:system_node_module_assignment, node: node, node_module: node_module, enabled: true) }

  describe "GET /api/v1/system/node_module_assignments/:id" do
    it "returns the assignment payload" do
      get "/api/v1/system/node_module_assignments/#{assignment.id}", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.dig("data", "node_module_assignment", "id")).to eq(assignment.id)
      expect(body.dig("data", "node_module_assignment", "enabled")).to be true
    end

    it "404s for an assignment in another account" do
      foreign_node = create(:system_node, account: other_account)
      foreign_module = create(:system_node_module, account: other_account)
      foreign_assignment = create(:system_node_module_assignment,
                                  node: foreign_node, node_module: foreign_module)

      get "/api/v1/system/node_module_assignments/#{foreign_assignment.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/node_module_assignments/:id/disable" do
    it "sets enabled=false and persists" do
      post "/api/v1/system/node_module_assignments/#{assignment.id}/disable", headers: headers

      expect(response).to have_http_status(:ok)
      expect(assignment.reload.enabled).to be false
    end

    it "is idempotent — disabling an already-disabled assignment succeeds" do
      assignment.update!(enabled: false)

      post "/api/v1/system/node_module_assignments/#{assignment.id}/disable", headers: headers

      expect(response).to have_http_status(:ok)
      expect(assignment.reload.enabled).to be false
    end

    it "removes the module from neighboring_modules_for(node)" do
      # Materialize the assignment for `node_module` first (let is lazy)
      assignment_id = assignment.id

      sibling = create(:system_node_module, account: account)
      create(:system_node_module_assignment, node: node, node_module: sibling, enabled: true)

      # Sanity: enabled assignment shows up
      expect(sibling.send(:neighboring_modules_for, node)).to include(node_module)

      post "/api/v1/system/node_module_assignments/#{assignment_id}/disable", headers: headers

      expect(sibling.send(:neighboring_modules_for, node)).not_to include(node_module)
    end
  end

  describe "POST /api/v1/system/node_module_assignments/:id/enable" do
    before { assignment.update!(enabled: false) }

    it "sets enabled=true and persists" do
      post "/api/v1/system/node_module_assignments/#{assignment.id}/enable", headers: headers

      expect(response).to have_http_status(:ok)
      expect(assignment.reload.enabled).to be true
    end

    it "is idempotent — enabling an already-enabled assignment succeeds" do
      assignment.update!(enabled: true)

      post "/api/v1/system/node_module_assignments/#{assignment.id}/enable", headers: headers

      expect(response).to have_http_status(:ok)
      expect(assignment.reload.enabled).to be true
    end
  end

  describe "permission gating" do
    let(:reader) { user_with_permissions("system.modules.read", account: account) }
    let(:reader_headers) { auth_headers_for(reader).merge("Content-Type" => "application/json") }

    it "rejects disable without system.modules.update" do
      post "/api/v1/system/node_module_assignments/#{assignment.id}/disable", headers: reader_headers

      expect(response).to have_http_status(:forbidden)
    end

    it "rejects show without any permission" do
      no_perm = create(:user, account: account)
      no_perm_headers = auth_headers_for(no_perm).merge("Content-Type" => "application/json")

      get "/api/v1/system/node_module_assignments/#{assignment.id}", headers: no_perm_headers

      expect(response).to have_http_status(:forbidden)
    end
  end
end
