# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator API — Node Templates import", type: :request do
  let(:account) { create(:account) }
  let(:user) do
    user_with_permissions("system.templates.read", "system.templates.create",
                          account: account)
  end
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  let(:platform_name) { "import-spec-platform-#{SecureRandom.hex(3)}" }
  let!(:platform) { create(:system_node_platform, account: account, name: platform_name) }
  let(:category) { create(:system_node_module_category, account: account) }

  let!(:mod_a) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription",
           name: "import-spec-a-#{SecureRandom.hex(3)}")
  end
  let!(:mod_b) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription",
           name: "import-spec-b-#{SecureRandom.hex(3)}")
  end

  def bundle_with(template_name:, modules:, **overrides)
    {
      format_version: "1.0",
      kind: "system.node_template",
      exported_at: Time.current.iso8601,
      template: {
        name: template_name, description: "imported", enabled: true, public: false,
        admin_user: "ubuntu", config: {}
      },
      platform: { name: platform_name, architecture_name: "x86_64" },
      modules: modules
    }.merge(overrides)
  end

  describe "POST /api/v1/system/node_templates/import" do
    it "creates a NodeTemplate + TemplateModules from a valid bundle" do
      bundle = bundle_with(
        template_name: "imported-template",
        modules: [
          { module_name: mod_a.name, module_variety: mod_a.variety, priority: 10, enabled: true, config: {} },
          { module_name: mod_b.name, module_variety: mod_b.variety, priority: 20, enabled: true, config: {} }
        ]
      )

      post "/api/v1/system/node_templates/import",
           params: { bundle: bundle }.to_json, headers: headers

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body.dig("data", "template_modules_count")).to eq(2)
      tmpl = ::System::NodeTemplate.find_by(account: account, name: "imported-template")
      expect(tmpl.template_modules.count).to eq(2)
    end

    it "uses the new_name override when provided" do
      bundle = bundle_with(template_name: "bundle-name",
                           modules: [ { module_name: mod_a.name, module_variety: mod_a.variety, priority: 5, enabled: true, config: {} } ])

      post "/api/v1/system/node_templates/import",
           params: { bundle: bundle, name: "renamed-on-import" }.to_json, headers: headers

      expect(response).to have_http_status(:created)
      expect(::System::NodeTemplate.find_by(account: account, name: "renamed-on-import")).not_to be_nil
      expect(::System::NodeTemplate.find_by(account: account, name: "bundle-name")).to be_nil
    end

    it "refuses with missing_modules detail when a module is absent in this account" do
      bundle = bundle_with(
        template_name: "partial-import",
        modules: [
          { module_name: mod_a.name, module_variety: mod_a.variety, priority: 5, enabled: true, config: {} },
          { module_name: "definitely-not-here", module_variety: "subscription", priority: 10, enabled: true, config: {} }
        ]
      )

      post "/api/v1/system/node_templates/import",
           params: { bundle: bundle }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      missing = body.dig("details", "missing_modules") || body.dig("data", "missing_modules") || body["details"]
      # whichever shape the platform's render_error chose for details
      expect(body["error"]).to match(/missing/i)
    end

    it "refuses unsupported format_version" do
      bundle = bundle_with(template_name: "wrong-format",
                           modules: [], format_version: "9.0")

      post "/api/v1/system/node_templates/import",
           params: { bundle: bundle }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/format_version/i)
    end

    it "refuses unsupported kind" do
      bundle = bundle_with(template_name: "wrong-kind",
                           modules: [], kind: "something-else")

      post "/api/v1/system/node_templates/import",
           params: { bundle: bundle }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/kind/i)
    end

    it "refuses when bundle param is absent" do
      post "/api/v1/system/node_templates/import",
           params: {}.to_json, headers: headers

      expect(response).to have_http_status(:bad_request)
    end

    it "refuses when the named platform isn't in the target account" do
      bundle = bundle_with(template_name: "no-platform",
                           modules: [ { module_name: mod_a.name, module_variety: mod_a.variety, priority: 5, enabled: true, config: {} } ],
                           platform: { name: "nonexistent-platform", architecture_name: "x86_64" })

      post "/api/v1/system/node_templates/import",
           params: { bundle: bundle }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/platform/i)
    end

    it "is symmetric with exporter — re-importing an exported bundle round-trips" do
      source = create(:system_node_template, account: account, node_platform: platform,
                      name: "roundtrip-source")
      ::System::TemplateModule.create!(node_template: source, node_module: mod_a, priority: 10)
      ::System::TemplateModule.create!(node_template: source, node_module: mod_b, priority: 20)

      export_result = ::System::TemplateExporter.export(template: source)
      bundle = export_result.data[:bundle]

      post "/api/v1/system/node_templates/import",
           params: { bundle: bundle, name: "roundtrip-target" }.to_json, headers: headers

      expect(response).to have_http_status(:created)
      target = ::System::NodeTemplate.find_by(account: account, name: "roundtrip-target")
      expect(target.template_modules.count).to eq(2)
      expect(target.template_modules.pluck(:node_module_id)).to contain_exactly(mod_a.id, mod_b.id)
    end

    context "permissions" do
      it "403s when the user lacks system.templates.create" do
        viewer = user_with_permissions("system.templates.read", account: account)
        viewer_headers = auth_headers_for(viewer).merge("Content-Type" => "application/json")
        bundle = bundle_with(template_name: "perm-check", modules: [])

        post "/api/v1/system/node_templates/import",
             params: { bundle: bundle }.to_json, headers: viewer_headers

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  # === Composition advisories (IMP-a2f8441f5f62) ===
  # An import materializes a whole template's joins in one transaction,
  # outside the delta guard the assignment write paths run — so a bundle that
  # composes badly lands as permanent baseline that later assignments are then
  # obliged to treat as acceptable. TemplateImporter reports that rather than
  # refusing (blocking would make an export/import round trip lossy); the HTTP
  # surface has to carry the report or the signal dies at the service boundary.
  describe "POST /api/v1/system/node_templates/import — composition advisories" do
    let!(:inst_a) do
      create(:system_node_module, account: account, node_platform: platform,
             category: category, variety: "instance",
             name: "import-inst-a-#{SecureRandom.hex(3)}")
    end
    let!(:inst_b) do
      create(:system_node_module, account: account, node_platform: platform,
             category: category, variety: "instance",
             name: "import-inst-b-#{SecureRandom.hex(3)}")
    end

    it "surfaces the conflict under composition_report, severity-typed" do
      bundle = bundle_with(
        template_name: "colliding-import-#{SecureRandom.hex(3)}",
        modules: [
          { module_name: inst_a.name, module_variety: inst_a.variety, priority: 10, enabled: true, config: {} },
          { module_name: inst_b.name, module_variety: inst_b.variety, priority: 20, enabled: true, config: {} }
        ]
      )

      post "/api/v1/system/node_templates/import",
           params: { bundle: bundle }.to_json, headers: headers

      # Reported, NOT refused — the template still imports.
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body.dig("data", "template_modules_count")).to eq(2)

      # `composition_report`, not `warnings`: this surface REPORTS a blocking
      # verdict it does not enforce, and the assign paths use `warnings` for
      # genuinely advisory conflicts. Each entry states its own severity so a
      # caller can tell the two apart (IMP-493db0e5c398).
      report = body.dig("data", "composition_report")
      expect(report).to be_an(Array).and be_present
      blocking = report.select { |e| e["severity"] == "error" }
      expect(blocking.map { |e| e["kind"] }).to include("instance_variety_collision")
      expect(blocking.map { |e| e["module_ids"] }.flatten)
        .to include(inst_a.id).and include(inst_b.id)
      expect(body.dig("data", "warnings")).to be_nil
    end

    it "omits the composition_report key on a clean import, leaving the payload unchanged" do
      bundle = bundle_with(
        template_name: "clean-import-#{SecureRandom.hex(3)}",
        modules: [ { module_name: mod_a.name, module_variety: mod_a.variety, priority: 5, enabled: true, config: {} } ]
      )

      post "/api/v1/system/node_templates/import",
           params: { bundle: bundle }.to_json, headers: headers

      expect(response).to have_http_status(:created)
      data = JSON.parse(response.body)["data"]
      expect(data).not_to have_key("composition_report")
      expect(data).not_to have_key("warnings")
    end
  end
end
