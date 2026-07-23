# frozen_string_literal: true

require "rails_helper"

# IMP-5dba18916d37 — module-puppet assignment CRUD. show/update/destroy were
# declared FLAT (no :node_module_id) while the controller's unconditional
# set_node_module before_action requires it, so every flat call 404'd — the
# same class as IMP-20488c93ca35 (module_dependencies). All five actions are
# now nested under node_modules/:node_module_id.
RSpec.describe "Operator API — Module Puppet Assignments", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) do
    user_with_permissions(
      "system.puppet.read", "system.puppet.create",
      "system.puppet.update", "system.puppet.delete",
      account: account
    )
  end
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  let(:node_module) { create(:system_node_module, account: account) }
  let(:puppet_module) { create(:system_puppet_module, account: account) }
  let!(:assignment) do
    create(:system_module_puppet_assignment,
           node_module: node_module, puppet_module: puppet_module,
           enabled: true, priority: 5)
  end

  let(:base) { "/api/v1/system/node_modules/#{node_module.id}/module_puppet_assignments" }

  describe "GET index (nested)" do
    it "lists assignments for the module" do
      get base, headers: headers

      expect(response).to have_http_status(:ok)
      rows = JSON.parse(response.body).dig("data", "puppet_assignments")
      expect(rows.map { |r| r["id"] }).to include(assignment.id)
      expect(rows.first).to include("puppet_module_id" => puppet_module.id, "enabled" => true)
    end
  end

  describe "GET show (nested)" do
    it "returns the assignment" do
      get "#{base}/#{assignment.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "puppet_assignment", "id")).to eq(assignment.id)
    end
  end

  describe "POST create (nested)" do
    it "creates an assignment" do
      other_puppet = create(:system_puppet_module, account: account, name: "profile_extra")

      post base,
           params: { puppet_assignment: { puppet_module_id: other_puppet.id, priority: 9 } }.to_json,
           headers: headers

      expect(response).to have_http_status(:ok).or have_http_status(:created)
      row = JSON.parse(response.body).dig("data", "puppet_assignment")
      expect(row["puppet_module_id"]).to eq(other_puppet.id)
      expect(row["priority"]).to eq(9)
    end
  end

  describe "PATCH update (nested)" do
    it "toggles enabled and updates priority" do
      patch "#{base}/#{assignment.id}",
            params: { puppet_assignment: { enabled: false, priority: 2 } }.to_json,
            headers: headers

      expect(response).to have_http_status(:ok)
      expect(assignment.reload.enabled).to be false
      expect(assignment.priority).to eq(2)
    end
  end

  describe "DELETE destroy (nested)" do
    it "removes the assignment" do
      delete "#{base}/#{assignment.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(::System::ModulePuppetAssignment.exists?(assignment.id)).to be false
    end
  end

  describe "cross-account isolation" do
    it "404s for another account's node module" do
      foreign_module = create(:system_node_module, account: other_account)

      get "/api/v1/system/node_modules/#{foreign_module.id}/module_puppet_assignments",
          headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "permissions" do
    it "403s update without system.puppet.update" do
      reader = user_with_permissions("system.puppet.read", account: account)
      reader_headers = auth_headers_for(reader).merge("Content-Type" => "application/json")

      patch "#{base}/#{assignment.id}",
            params: { puppet_assignment: { enabled: false } }.to_json,
            headers: reader_headers

      expect(response).to have_http_status(:forbidden)
    end
  end
end
