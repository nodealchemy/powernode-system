# frozen_string_literal: true

require "rails_helper"

# REST surface for the TemplateModule join, served by
# Api::V1::System::TemplateModulesController (nested under node_templates):
#
#   GET    /api/v1/system/node_templates/:node_template_id/modules        → index
#   POST   /api/v1/system/node_templates/:node_template_id/modules        → create
#   PATCH  /api/v1/system/node_templates/:node_template_id/modules/:id    → update
#   DELETE /api/v1/system/node_templates/:node_template_id/modules/:id    → destroy
#
# create/update/destroy mirror the MCP `system_assign_module_to_template` /
# `system_update_template_module` / `unassign_module_from_template` actions
# (all key off the node_module id), giving the Visual Template Composer +
# TemplateDetailModal a REST path — previously TemplateModule mutation was
# MCP-only. Cross-account modules 404 (resolved within the current account);
# duplicates 422 (model uniqueness on node_template_id/node_module_id). The
# member :id for update/destroy is the NODE_MODULE id, not the join row's
# own id.
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

    it "leaves a clean assignment's payload unchanged — no conflict keys" do
      post "/api/v1/system/node_templates/#{template.id}/modules",
           params: { node_module_id: node_module.id }.to_json, headers: headers

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["data"].keys).to contain_exactly("template_module")
    end
  end

  # === Composition-conflict enforcement (IMP-20b3eb50da30) ===
  # Conflict detection used to run ONLY in compose_preview, so the sole thing
  # standing between an operator and a template that cannot build was a
  # disabled button in the React composer. The write path now runs the same
  # TemplateComposerService analysis over the resulting module set: hard
  # conflicts refuse the assignment, soft ones ride the success payload.
  describe "POST .../modules — composition conflicts" do
    let(:other_category) do
      create(:system_node_module_category, account: account, name: "conflict-cat-#{SecureRandom.hex(3)}")
    end

    def composition_module(name, category: other_category, variety: "subscription")
      create(:system_node_module, account: account, node_platform: platform,
             category: category, variety: variety, name: "#{name}-#{SecureRandom.hex(3)}")
    end

    def assign(node_module)
      post "/api/v1/system/node_templates/#{template.id}/modules",
           params: { node_module_id: node_module.id }.to_json, headers: headers
    end

    it "422s and creates nothing when the assignment collides on instance variety" do
      first  = composition_module("inst-first", variety: "instance")
      second = composition_module("inst-second", variety: "instance")
      assign(first)
      expect(response).to have_http_status(:created)

      expect { assign(second) }.not_to change { template.template_modules.count }

      expect(response).to have_http_status(:unprocessable_content)
      error = JSON.parse(response.body)["error"]
      expect(error).to include(first.name).and include(second.name)
      expect(::System::TemplateModule.find_by(node_template: template, node_module: second)).to be_nil
    end

    it "422s when the incoming module declares a Conflicts: relation on an assigned one" do
      installed = composition_module("conf-installed")
      incoming  = composition_module("conf-incoming")
      create(:system_module_dependency, node_module: incoming, dependency: installed,
             dependency_type: "conflicts", required: false)
      assign(installed)
      expect(response).to have_http_status(:created)

      expect { assign(incoming) }.not_to change { template.template_modules.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include(incoming.name).and include(installed.name)
    end

    it "creates the join and returns warnings for a protected_spec overlap" do
      claimer = composition_module("warn-claimer")
      claimer.update!(protected_spec: "/etc/shadow")
      broad = composition_module("warn-broad")
      broad.update!(file_spec: "/etc/**")
      assign(claimer)
      expect(response).to have_http_status(:created)

      expect { assign(broad) }.to change { template.template_modules.count }.by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      warning = body.dig("data", "warnings")&.first
      expect(warning).to be_present
      expect(warning["kind"]).to eq("protected_spec_overlap")
      expect(warning["severity"]).to eq("warning")
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

  # === Join attributes (IMP-5c340c72ff9a) ===
  # create took only node_module_id, and there was no update path at all — so
  # priority, enabled, config and recommends_override were unreachable from
  # every write API. That made the documented-correct removal (disable, never
  # destroy) inexpressible, leaving the destructive DELETE as the only way to
  # take a module out of a template.
  describe "join attributes on POST .../modules" do
    it "persists priority, enabled, config and recommends_override" do
      post "/api/v1/system/node_templates/#{template.id}/modules",
           params: { node_module_id: node_module.id, priority: 40, enabled: false,
                     config: { "port" => 8080 },
                     recommends_override: { "excluded" => [ "docs" ] } }.to_json,
           headers: headers

      expect(response).to have_http_status(:created)
      join = ::System::TemplateModule.find(JSON.parse(response.body).dig("data", "template_module", "id"))
      expect(join.priority).to eq(40)
      expect(join.enabled).to be false
      expect(join.config["port"]).to eq(8080)
      expect(join.recommends_override["excluded"]).to eq([ "docs" ])
    end
  end

  describe "PATCH /api/v1/system/node_templates/:node_template_id/modules/:id" do
    let(:other_category) do
      create(:system_node_module_category, account: account, name: "patch-cat-#{SecureRandom.hex(3)}")
    end

    def composition_module(name, category: other_category, variety: "subscription")
      create(:system_node_module, account: account, node_platform: platform,
             category: category, variety: variety, name: "#{name}-#{SecureRandom.hex(3)}")
    end

    def assign(node_module, **body)
      post "/api/v1/system/node_templates/#{template.id}/modules",
           params: { node_module_id: node_module.id }.merge(body).to_json, headers: headers
    end

    def patch_join(node_module, **body)
      patch "/api/v1/system/node_templates/#{template.id}/modules/#{node_module.id}",
            params: body.to_json, headers: headers
    end

    it "disables a join without destroying it" do
      join = ::System::TemplateModule.create!(node_template: template, node_module: node_module)

      expect do
        patch_join(node_module, enabled: false)
      end.not_to change { template.template_modules.count }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "template_module", "enabled")).to be false
      expect(join.reload.enabled).to be false
    end

    it "updates priority, config and recommends_override" do
      join = ::System::TemplateModule.create!(node_template: template, node_module: node_module)

      patch_join(node_module, priority: 7, config: { "threads" => 4 },
                              recommends_override: { "included" => [ "extras" ] })

      expect(response).to have_http_status(:ok)
      join.reload
      expect(join.priority).to eq(7)
      expect(join.config["threads"]).to eq(4)
      expect(join.recommends_override["included"]).to eq([ "extras" ])
    end

    it "404s when the module is not assigned to the template" do
      patch_join(node_module, enabled: false)

      expect(response).to have_http_status(:not_found)
    end

    it "403s when the user lacks system.templates.update" do
      ::System::TemplateModule.create!(node_template: template, node_module: node_module)
      viewer = user_with_permissions("system.templates.read", account: account)
      viewer_headers = auth_headers_for(viewer).merge("Content-Type" => "application/json")

      patch "/api/v1/system/node_templates/#{template.id}/modules/#{node_module.id}",
            params: { enabled: false }.to_json, headers: viewer_headers

      expect(response).to have_http_status(:forbidden)
    end

    # A disabled join never ships (TemplateExpansionService is enabled-only),
    # so it cannot collide — but enabling one is the moment it starts shipping,
    # and the guard has to run there instead.
    it "accepts a disabled assignment that would collide if it were enabled" do
      first  = composition_module("rest-dis-first", variety: "instance")
      second = composition_module("rest-dis-second", variety: "instance")
      assign(first)
      expect(response).to have_http_status(:created)

      assign(second, enabled: false)

      expect(response).to have_http_status(:created)
      expect(::System::TemplateModule.find_by(node_template: template, node_module: second).enabled).to be false
    end

    it "422s enabling a join that would introduce a conflict, and leaves it disabled" do
      first  = composition_module("rest-en-first", variety: "instance")
      second = composition_module("rest-en-second", variety: "instance")
      assign(first)
      assign(second, enabled: false)
      expect(response).to have_http_status(:created)

      patch_join(second, enabled: true)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include(first.name).and include(second.name)
      expect(::System::TemplateModule.find_by(node_template: template, node_module: second).enabled).to be false
    end

    # `enabled` is cast via ActiveModel::Type::Boolean before the conflict
    # guard above ever sees it, so a JSON body that sends the STRING "true"
    # (rather than the boolean) must be refused identically — never treated
    # as truthy because it's a non-empty string.
    it "422s enabling a join that would introduce a conflict when enabled arrives as the string 'true'" do
      first  = composition_module("rest-cast-first", variety: "instance")
      second = composition_module("rest-cast-second", variety: "instance")
      assign(first)
      assign(second, enabled: false)
      expect(response).to have_http_status(:created)

      patch_join(second, enabled: "true")

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include(first.name).and include(second.name)
      expect(::System::TemplateModule.find_by(node_template: template, node_module: second).enabled).to be false
    end
  end
end
