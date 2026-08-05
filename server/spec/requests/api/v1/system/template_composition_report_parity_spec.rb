# frozen_string_literal: true

require "rails_helper"

# IMP-493db0e5c398 — `warnings` meant SOFT on two template surfaces and HARD on
# the other two.
#
# Four surfaces run the same TemplateCompositionAnalysis and all four report
# under a key called `warnings`, but they meant opposite things by it:
#
#   ENFORCING (refuse on error severity, `warnings` = genuinely advisory)
#     - POST .../node_templates/:id/modules            (TemplateModulesController#create)
#     - system_assign_module_to_template               (SystemFleetTool)
#
#   REPORTING (succeed, `warnings` = a BLOCKING verdict that was not enforced)
#     - POST .../node_templates/import                 (TemplateImporter)
#     - POST .../node_templates/:id/clone              (TemplateCloneService)
#
# A caller holding one of these payloads could not tell which it had. The fix
# is NOT to unify enforcement — TemplateCloneService and TemplateImporter
# report deliberately, because forking or re-importing a broken template is how
# an operator gets a copy to repair — it is to make the payload say which kind
# of verdict it is carrying. Hence: every entry states its own severity.
#
# A type-only fix (making all four emit the same element TYPE, without
# severity) would keep the trap, so the assertions below are on severity, not
# on shape.
RSpec.describe "Template composition report parity", type: :request do
  let(:account) { create(:account) }
  let(:user) do
    user_with_permissions("system.templates.read", "system.templates.create",
                          "system.templates.update", account: account)
  end
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  let(:platform_name) { "parity-platform-#{SecureRandom.hex(3)}" }
  let!(:platform) { create(:system_node_platform, account: account, name: platform_name) }
  let(:cat_one) { create(:system_node_module_category, account: account, name: "parity-one-#{SecureRandom.hex(3)}") }
  let(:cat_two) { create(:system_node_module_category, account: account, name: "parity-two-#{SecureRandom.hex(3)}") }

  let(:template) do
    create(:system_node_template, account: account, node_platform: platform,
           name: "parity-src-#{SecureRandom.hex(3)}")
  end

  # Names that won't collide with the account bootstrap's default catalog.
  def node_module(name, category: cat_one, variety: "subscription")
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: variety, name: "#{name}-#{SecureRandom.hex(3)}")
  end

  # Attaches without going through a guarded write path, so a spec can set up
  # state the guard would have refused.
  def preassign(mod, on: template, enabled: true)
    ::System::TemplateModule.create!(node_template: on, node_module: mod, enabled: enabled)
  end

  # ── The single lens a caller actually has ────────────────────────────────
  # A caller does not know which key a given surface picked, so read both and
  # judge the ENTRIES. That is precisely the question this file exists to
  # answer: can one rule classify a verdict without knowing which surface
  # produced it?
  def composition_entries(data)
    raw = data["composition_report"] || data["warnings"]
    Array(raw).map { |e| e.is_a?(Hash) ? e.deep_stringify_keys : e }
  end

  def blocking_entries(data)
    composition_entries(data).select { |e| e.is_a?(Hash) && e["severity"] == "error" }
  end

  def advisory_entries(data)
    composition_entries(data).select { |e| e.is_a?(Hash) && e["severity"] == "warning" }
  end

  # ── Fixtures for the two severities ──────────────────────────────────────
  # error: two instance-variety modules in one category.
  # warning: a protected_spec claim another module's file_spec covers.
  def colliding_pair
    [ node_module("inst-a", variety: "instance"), node_module("inst-b", variety: "instance") ]
  end

  def overlapping_pair
    claimer = node_module("claimer")
    claimer.update!(protected_spec: "/etc/shadow")
    broad = node_module("broad", category: cat_two)
    broad.update!(file_spec: "/etc/**")
    [ claimer, broad ]
  end

  def json = JSON.parse(response.body)

  # ── Surface drivers — each returns the success payload ───────────────────

  # ENFORCING #1 — REST assign, advisory conflict (succeeds, reports).
  def rest_assign_advisory
    claimer, broad = overlapping_pair
    preassign(claimer)
    post "/api/v1/system/node_templates/#{template.id}/modules",
         params: { node_module_id: broad.id }.to_json, headers: headers
    expect(response).to have_http_status(:created)
    json["data"]
  end

  # ENFORCING #2 — MCP assign, advisory conflict (succeeds, reports).
  def mcp_assign_advisory
    claimer, broad = overlapping_pair
    preassign(claimer)
    result = ::Ai::Tools::SystemFleetTool.new(account: account, internal: true).execute(
      params: { action: "system_assign_module_to_template",
                template_id: template.id, module_id: broad.id }
    )
    expect(result[:success]).to be(true)
    result[:data].deep_stringify_keys
  end

  # REPORTING #1 — import a bundle that composes badly (succeeds, reports).
  def import_blocking
    inst_a, inst_b = colliding_pair
    bundle = {
      format_version: "1.0", kind: "system.node_template",
      exported_at: Time.current.iso8601,
      template: { name: "parity-import-#{SecureRandom.hex(3)}", description: "d",
                  enabled: true, public: false, admin_user: "ubuntu", config: {} },
      platform: { name: platform_name, architecture_name: "x86_64" },
      modules: [
        { module_name: inst_a.name, module_variety: inst_a.variety, priority: 10, enabled: true, config: {} },
        { module_name: inst_b.name, module_variety: inst_b.variety, priority: 20, enabled: true, config: {} }
      ]
    }
    post "/api/v1/system/node_templates/import",
         params: { bundle: bundle }.to_json, headers: headers
    expect(response).to have_http_status(:created)
    json["data"]
  end

  # REPORTING #2 — clone a template that already composes badly (succeeds).
  def clone_blocking
    inst_a, inst_b = colliding_pair
    preassign(inst_a)
    preassign(inst_b)
    post "/api/v1/system/node_templates/#{template.id}/clone",
         params: { name: "parity-clone-#{SecureRandom.hex(3)}" }.to_json, headers: headers
    expect(response).to have_http_status(:created)
    json["data"]
  end

  # ── The defect ───────────────────────────────────────────────────────────

  describe "every surface states the severity of what it reports" do
    it "REST assign — advisory entry carries severity" do
      data = rest_assign_advisory
      expect(composition_entries(data)).to be_present
      composition_entries(data).each do |entry|
        expect(entry).to be_a(Hash), "reported an untyped entry: #{entry.inspect}"
        expect(entry["severity"]).to be_in(%w[error warning]),
                                     "entry states no severity: #{entry.inspect}"
      end
    end

    it "MCP assign — advisory entry carries severity" do
      data = mcp_assign_advisory
      expect(composition_entries(data)).to be_present
      composition_entries(data).each do |entry|
        expect(entry).to be_a(Hash), "reported an untyped entry: #{entry.inspect}"
        expect(entry["severity"]).to be_in(%w[error warning]),
                                     "entry states no severity: #{entry.inspect}"
      end
    end

    it "import — blocking entry carries severity" do
      data = import_blocking
      expect(composition_entries(data)).to be_present
      composition_entries(data).each do |entry|
        expect(entry).to be_a(Hash), "reported an untyped entry: #{entry.inspect}"
        expect(entry["severity"]).to be_in(%w[error warning]),
                                     "entry states no severity: #{entry.inspect}"
      end
    end

    it "clone — blocking entry carries severity" do
      data = clone_blocking
      expect(composition_entries(data)).to be_present
      composition_entries(data).each do |entry|
        expect(entry).to be_a(Hash), "reported an untyped entry: #{entry.inspect}"
        expect(entry["severity"]).to be_in(%w[error warning]),
                                     "entry states no severity: #{entry.inspect}"
      end
    end
  end

  describe "one classifier, applied blind, gets the right answer everywhere" do
    it "classifies the enforcing surfaces' reports as advisory" do
      expect(blocking_entries(rest_assign_advisory)).to be_empty
      expect(advisory_entries(rest_assign_advisory)).to be_present
    end

    it "classifies the MCP enforcing surface's report as advisory" do
      data = mcp_assign_advisory
      expect(blocking_entries(data)).to be_empty
      expect(advisory_entries(data)).to be_present
    end

    it "classifies the import report as blocking, naming the modules" do
      data = import_blocking
      blocking = blocking_entries(data)
      expect(blocking).to be_present
      expect(blocking.map { |e| e["kind"] }).to include("instance_variety_collision")
    end

    it "classifies the clone report as blocking, naming the modules" do
      data = clone_blocking
      blocking = blocking_entries(data)
      expect(blocking).to be_present
      expect(blocking.map { |e| e["kind"] }).to include("instance_variety_collision")
    end
  end

  # ── The trap: enforcement must NOT be unified ────────────────────────────
  # TemplateCloneService and TemplateImporter report deliberately. Forking or
  # re-importing a broken template is exactly how an operator gets a copy to
  # repair, and blocking import would make an export/import round trip lossy.
  # These pin that decision so a future maintainer cannot quietly "fix the
  # inconsistency" by making them refuse.
  describe "enforcement is UNCHANGED on all four surfaces" do
    it "REST assign still REFUSES an error-severity conflict" do
      inst_a, inst_b = colliding_pair
      preassign(inst_a)

      post "/api/v1/system/node_templates/#{template.id}/modules",
           params: { node_module_id: inst_b.id }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(template.template_modules.where(node_module_id: inst_b.id)).to be_empty
    end

    it "MCP assign still REFUSES an error-severity conflict" do
      inst_a, inst_b = colliding_pair
      preassign(inst_a)

      result = ::Ai::Tools::SystemFleetTool.new(account: account, internal: true).execute(
        params: { action: "system_assign_module_to_template",
                  template_id: template.id, module_id: inst_b.id }
      )

      expect(result[:success]).to be(false)
      expect(result[:error]).to include("instance_variety_collision")
      expect(template.template_modules.where(node_module_id: inst_b.id)).to be_empty
    end

    it "import still SUCCEEDS on a bundle that composes badly" do
      data = import_blocking

      expect(response).to have_http_status(:created)
      expect(data["template_modules_count"]).to eq(2)
      expect(::System::NodeTemplate.find(data.dig("node_template", "id"))
                                   .template_modules.count).to eq(2)
    end

    it "clone still SUCCEEDS on a template that composes badly" do
      data = clone_blocking

      expect(response).to have_http_status(:created)
      cloned = ::System::NodeTemplate.find(data.dig("node_template", "id"))
      expect(cloned).to be_persisted
      expect(cloned.template_modules.count).to eq(2)
    end
  end

  describe "a clean composition reports nothing at all" do
    it "omits the key on a clean REST assign" do
      post "/api/v1/system/node_templates/#{template.id}/modules",
           params: { node_module_id: node_module("solo").id }.to_json, headers: headers

      expect(response).to have_http_status(:created)
      expect(json["data"]).not_to have_key("warnings")
      expect(json["data"]).not_to have_key("composition_report")
    end

    it "omits the key on a clean clone" do
      preassign(node_module("solo"))

      post "/api/v1/system/node_templates/#{template.id}/clone",
           params: { name: "parity-clean-#{SecureRandom.hex(3)}" }.to_json, headers: headers

      expect(response).to have_http_status(:created)
      expect(json["data"]).not_to have_key("warnings")
      expect(json["data"]).not_to have_key("composition_report")
    end
  end
end
