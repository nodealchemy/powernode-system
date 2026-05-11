# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator API — Node Templates clone", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) do
    user_with_permissions("system.templates.read", "system.templates.create",
                          "system.templates.update", account: account)
  end
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:source_template) do
    create(:system_node_template, account: account, node_platform: platform,
           name: "base-web", description: "Source")
  end
  # Use names that won't collide with the account-bootstrap's default
  # module catalog (system-base, nginx, openssl, etc.).
  let(:openssl_mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "clone-spec-openssl-#{SecureRandom.hex(3)}")
  end
  let(:nginx_mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "clone-spec-nginx-#{SecureRandom.hex(3)}")
  end

  before do
    ::System::TemplateModule.create!(
      node_template: source_template, node_module: openssl_mod,
      priority: 50, enabled: true
    )
    ::System::TemplateModule.create!(
      node_template: source_template, node_module: nginx_mod,
      priority: 30, enabled: true,
      recommends_override: { "excluded" => ["nginx-extras"] }
    )
  end

  describe "POST /api/v1/system/node_templates/:id/clone" do
    it "creates a new template with the default '-copy' suffix when no name given" do
      post "/api/v1/system/node_templates/#{source_template.id}/clone", headers: headers

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body.dig("data", "node_template", "name")).to eq("base-web-copy")
      expect(body.dig("data", "node_template", "id")).not_to eq(source_template.id)
    end

    it "uses the operator-supplied name when provided" do
      post "/api/v1/system/node_templates/#{source_template.id}/clone",
           params: { name: "base-web-2" }.to_json, headers: headers

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body).dig("data", "node_template", "name")).to eq("base-web-2")
    end

    it "deep-copies every TemplateModule row with priority + recommends_override preserved" do
      post "/api/v1/system/node_templates/#{source_template.id}/clone",
           params: { name: "deep-copy-test" }.to_json, headers: headers

      new_template = ::System::NodeTemplate.find_by(account: account, name: "deep-copy-test")
      expect(new_template).not_to be_nil
      expect(new_template.template_modules.count).to eq(2)

      ssl_join = new_template.template_modules.find_by(node_module_id: openssl_mod.id)
      nginx_join = new_template.template_modules.find_by(node_module_id: nginx_mod.id)
      expect(ssl_join.priority).to eq(50)
      expect(nginx_join.recommends_override).to eq("excluded" => [ "nginx-extras" ])
    end

    it "422s when the new name collides with an existing template in the same account" do
      create(:system_node_template, account: account, node_platform: platform, name: "base-web-copy")

      post "/api/v1/system/node_templates/#{source_template.id}/clone", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/name|taken/i)
    end

    it "404s when the source template belongs to another account" do
      foreign_platform = create(:system_node_platform, account: other_account)
      foreign_template = create(:system_node_template, account: other_account,
                                node_platform: foreign_platform, name: "foreign")

      post "/api/v1/system/node_templates/#{foreign_template.id}/clone", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "403s when the user lacks system.templates.create" do
      viewer = user_with_permissions("system.templates.read", account: account)
      viewer_headers = auth_headers_for(viewer).merge("Content-Type" => "application/json")

      post "/api/v1/system/node_templates/#{source_template.id}/clone", headers: viewer_headers

      expect(response).to have_http_status(:forbidden)
    end
  end
end
