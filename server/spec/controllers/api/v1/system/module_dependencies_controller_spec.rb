# frozen_string_literal: true

require "rails_helper"

# IMP-20488c93ca35 — module_dependencies was a top-level flat resource in
# routes.rb, but ModuleDependenciesController#set_node_module requires
# params[:node_module_id], which a flat route never populates. Every real
# request 500'd (`.find(nil)` -> ActiveRecord::RecordNotFound) regardless of
# caller. Fixed by nesting the resource under node_modules/:node_module_id
# (matching the model's node_module_id FK, the has_many :module_dependencies
# association, and the controller's existing param name), using the
# controller's own segment name so it doesn't collide with
# NodeModulesController's unrelated `member { get :dependencies }` action.
RSpec.describe "Api::V1::System::ModuleDependencies", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.modules.read", account: account) }
  let(:update_user) { user_with_permissions("system.modules.update", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let(:node_module)      { create(:system_node_module, account: account) }
  let(:required_module)  { create(:system_node_module, account: account) }
  let!(:dependency) do
    create(:system_module_dependency, node_module: node_module, dependency: required_module)
  end

  describe "GET /api/v1/system/node_modules/:node_module_id/module_dependencies" do
    it "returns 401 without auth" do
      get "/api/v1/system/node_modules/#{node_module.id}/module_dependencies"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/node_modules/#{node_module.id}/module_dependencies",
          headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "lists dependencies for the module" do
      get "/api/v1/system/node_modules/#{node_module.id}/module_dependencies",
          headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"]["dependencies"].map { |d| d["id"] }).to contain_exactly(dependency.id)
    end

    it "returns 404 for another account's module" do
      foreign_module = create(:system_node_module, account: other_account)
      get "/api/v1/system/node_modules/#{foreign_module.id}/module_dependencies",
          headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/node_modules/:node_module_id/module_dependencies" do
    it "creates a dependency scoped to the module" do
      another_module = create(:system_node_module, account: account)
      post "/api/v1/system/node_modules/#{node_module.id}/module_dependencies",
           params: {
             dependency: { dependency_id: another_module.id, dependency_type: "requires", required: true }
           }.to_json,
           headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:created)
      expect(node_module.module_dependencies.count).to eq(2)
    end
  end

  describe "DELETE /api/v1/system/node_modules/:node_module_id/module_dependencies/:id" do
    it "removes the dependency" do
      delete "/api/v1/system/node_modules/#{node_module.id}/module_dependencies/#{dependency.id}",
             headers: auth_headers_for(update_user)
      expect(response).to have_http_status(:ok)
      expect(node_module.module_dependencies.count).to eq(0)
    end
  end
end
