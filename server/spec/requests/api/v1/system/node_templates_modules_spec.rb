# frozen_string_literal: true

require "rails_helper"

# REST surface for the TemplateModule join, served by
# Api::V1::System::TemplateModulesController (nested under node_templates):
#
#   GET    /api/v1/system/node_templates/:node_template_id/modules        → index
#   POST   /api/v1/system/node_templates/:node_template_id/modules        → create
#   DELETE /api/v1/system/node_templates/:node_template_id/modules/:id    → destroy
#
# create/destroy mirror the MCP `system_assign_module_to_template` /
# `unassign_module_from_template` actions (both key off the node_module id),
# giving the Visual Template Composer + TemplateDetailModal a REST path —
# previously TemplateModule mutation was MCP-only. Cross-account modules 404
# (resolved within the current account); duplicates 422 (model uniqueness on
# node_template_id/node_module_id). The member :id for destroy is the
# NODE_MODULE id, not the join row's own id.
RSpec.describe "Operator API — Node Template modules", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) do
    user_with_permissions("system.templates.read", "system.templates.update", account: account)
  end
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) do
    create(:system_node_template, account: account, node_platform: platform, name: "assign-base")
  end
  # Use a name that won't collide with the account-bootstrap's default
  # module catalog (system-base, nginx, openssl, etc.).
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription",
           name: "assign-spec-mod-#{SecureRandom.hex(3)}")
  end

  describe "POST /api/v1/system/node_templates/:node_template_id/modules" do
    it "assigns the module to the template and creates the join row" do
      # Reference the records up front so the account-bootstrap's default
      # module catalog (which lazily seeds TemplateModule rows on first
      # account materialization) is excluded from the delta below; scope the
      # count to THIS template's joins, not the global table.
      template_id = template.id
      module_id = node_module.id

      expect do
        post "/api/v1/system/node_templates/#{template_id}/modules",
             params: { node_module_id: module_id }.to_json, headers: headers
      end.to change { template.template_modules.count }.by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      expect(body.dig("data", "template_module", "node_template_id")).to eq(template.id)
      expect(body.dig("data", "template_module", "node_module_id")).to eq(node_module.id)

      join = ::System::TemplateModule.find(body.dig("data", "template_module", "id"))
      expect(join.node_template_id).to eq(template.id)
      expect(join.node_module_id).to eq(node_module.id)
    end

    it "422s when node_module_id is blank" do
      template_id = template.id

      expect do
        post "/api/v1/system/node_templates/#{template_id}/modules",
             params: { node_module_id: "" }.to_json, headers: headers
      end.not_to change { template.template_modules.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/node_module_id/i)
    end

    it "404s when the module does not exist" do
      post "/api/v1/system/node_templates/#{template.id}/modules",
           params: { node_module_id: SecureRandom.uuid }.to_json, headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "404s when the module belongs to another account (no existence leak)" do
      foreign_platform = create(:system_node_platform, account: other_account)
      foreign_category = create(:system_node_module_category, account: other_account)
      foreign_module = create(:system_node_module, account: other_account,
                              node_platform: foreign_platform, category: foreign_category,
                              variety: "subscription", name: "foreign-mod-#{SecureRandom.hex(3)}")
      template_id = template.id

      expect do
        post "/api/v1/system/node_templates/#{template_id}/modules",
             params: { node_module_id: foreign_module.id }.to_json, headers: headers
      end.not_to change { template.template_modules.count }

      expect(response).to have_http_status(:not_found)
    end

    it "422s when the module is already assigned (duplicate join)" do
      ::System::TemplateModule.create!(node_template: template, node_module: node_module)
      template_id = template.id

      expect do
        post "/api/v1/system/node_templates/#{template_id}/modules",
             params: { node_module_id: node_module.id }.to_json, headers: headers
      end.not_to change { template.template_modules.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/already has this module/i)
    end

    it "403s when the user lacks system.templates.update" do
      viewer = user_with_permissions("system.templates.read", account: account)
      viewer_headers = auth_headers_for(viewer).merge("Content-Type" => "application/json")

      post "/api/v1/system/node_templates/#{template.id}/modules",
           params: { node_module_id: node_module.id }.to_json, headers: viewer_headers

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/system/node_templates/:node_template_id/modules" do
    it "returns the assigned modules under the node_modules key" do
      ::System::TemplateModule.create!(node_template: template, node_module: node_module)

      get "/api/v1/system/node_templates/#{template.id}/modules", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      node_modules = body.dig("data", "node_modules")
      expect(node_modules).to be_an(Array)
      expect(node_modules.map { |m| m["id"] }).to include(node_module.id)
    end

    it "403s when the user lacks system.templates.read" do
      stranger = user_with_permissions("system.nodes.read", account: account)
      stranger_headers = auth_headers_for(stranger).merge("Content-Type" => "application/json")

      get "/api/v1/system/node_templates/#{template.id}/modules", headers: stranger_headers

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /api/v1/system/node_templates/:node_template_id/modules/:id" do
    it "detaches the module and destroys the join row" do
      ::System::TemplateModule.create!(node_template: template, node_module: node_module)
      template_id = template.id
      module_id = node_module.id

      expect do
        delete "/api/v1/system/node_templates/#{template_id}/modules/#{module_id}", headers: headers
      end.to change { template.template_modules.count }.by(-1)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      expect(body.dig("data", "message")).to match(/removed/i)
      expect(::System::TemplateModule.find_by(node_template_id: template.id, node_module_id: module_id)).to be_nil
    end

    it "404s when the module is not assigned to the template" do
      delete "/api/v1/system/node_templates/#{template.id}/modules/#{node_module.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "403s when the user lacks system.templates.update" do
      ::System::TemplateModule.create!(node_template: template, node_module: node_module)
      viewer = user_with_permissions("system.templates.read", account: account)
      viewer_headers = auth_headers_for(viewer).merge("Content-Type" => "application/json")

      delete "/api/v1/system/node_templates/#{template.id}/modules/#{node_module.id}", headers: viewer_headers

      expect(response).to have_http_status(:forbidden)
    end
  end
end
