# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — operator CRUD controller spec for node_templates.
#
# NodeTemplatesController is the most complex shape in wave 1: full CRUD plus
# 5 member/collection actions (export, modules, clone, compose_preview,
# import). Per-permission gates use the system.templates.* permission family.
RSpec.describe "Api::V1::System::NodeTemplates", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.templates.read",   account: account) }
  let(:create_user) { user_with_permissions("system.templates.create", account: account) }
  let(:update_user) { user_with_permissions("system.templates.update", account: account) }
  let(:delete_user) { user_with_permissions("system.templates.delete", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let(:platform) { create(:system_node_platform, account: account) }
  let!(:template) { create(:system_node_template, account: account, node_platform: platform) }

  describe "GET /api/v1/system/node_templates" do
    it "returns 401 without auth" do
      get "/api/v1/system/node_templates"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/node_templates", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns the caller's templates" do
      get "/api/v1/system/node_templates", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      ids = json_response_data["node_templates"].map { |t| t["id"] }
      expect(ids).to include(template.id)
    end

    it "scopes to the caller's account" do
      foreign = create(:system_node_template,
                       account: other_account,
                       node_platform: create(:system_node_platform, account: other_account))
      get "/api/v1/system/node_templates", headers: auth_headers_for(read_user)
      ids = json_response_data["node_templates"].map { |t| t["id"] }
      expect(ids).not_to include(foreign.id)
    end
  end

  describe "GET /api/v1/system/node_templates/:id" do
    it "returns 404 for another account's template" do
      foreign = create(:system_node_template,
                       account: other_account,
                       node_platform: create(:system_node_platform, account: other_account))
      get "/api/v1/system/node_templates/#{foreign.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end

    it "returns the template" do
      get "/api/v1/system/node_templates/#{template.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["node_template"]["id"]).to eq(template.id)
    end
  end

  describe "POST /api/v1/system/node_templates" do
    let(:create_params) do
      { node_template: { name: "spec-tpl-#{SecureRandom.hex(3)}", node_platform_id: platform.id } }
    end

    it "returns 403 without create perm" do
      post "/api/v1/system/node_templates", params: create_params.to_json,
                                            headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "creates a template scoped to the caller's account" do
      expect {
        post "/api/v1/system/node_templates", params: create_params.to_json,
                                              headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      }.to change { ::System::NodeTemplate.where(account: account).count }.by(1)
      expect(response).to have_http_status(:created)
    end

    it "returns 422 on missing name" do
      post "/api/v1/system/node_templates",
           params: { node_template: { node_platform_id: platform.id } }.to_json,
           headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH /api/v1/system/node_templates/:id" do
    it "updates the template" do
      patch "/api/v1/system/node_templates/#{template.id}",
            params: { node_template: { description: "renamed" } }.to_json,
            headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(template.reload.description).to eq("renamed")
    end
  end

  describe "DELETE /api/v1/system/node_templates/:id" do
    it "deletes the template" do
      expect {
        delete "/api/v1/system/node_templates/#{template.id}", headers: auth_headers_for(delete_user)
      }.to change { ::System::NodeTemplate.where(account: account).count }.by(-1)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/v1/system/node_templates/:id/modules" do
    it "returns 403 without read perm" do
      get "/api/v1/system/node_templates/#{template.id}/modules", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns the template's modules" do
      get "/api/v1/system/node_templates/#{template.id}/modules", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data).to have_key("node_modules")
    end
  end

  describe "GET /api/v1/system/node_templates/:id/export" do
    it "returns 200 with a JSON attachment for templates the caller can read" do
      get "/api/v1/system/node_templates/#{template.id}/export", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Disposition"]).to include("attachment")
    end
  end

  describe "POST /api/v1/system/node_templates/:id/clone" do
    it "returns 403 without create perm" do
      post "/api/v1/system/node_templates/#{template.id}/clone",
           params: {}.to_json,
           headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "deep-clones a template" do
      expect {
        post "/api/v1/system/node_templates/#{template.id}/clone",
             params: { name: "spec-clone-#{SecureRandom.hex(3)}" }.to_json,
             headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      }.to change { ::System::NodeTemplate.where(account: account).count }.by(1)
      expect(response).to have_http_status(:created)
    end
  end

  describe "POST /api/v1/system/node_templates/compose_preview" do
    it "returns 422 when no module_ids supplied" do
      post "/api/v1/system/node_templates/compose_preview",
           params: { module_ids: [] }.to_json,
           headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_entity)
    end
  end
end
