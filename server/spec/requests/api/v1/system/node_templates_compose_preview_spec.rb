# frozen_string_literal: true

require "rails_helper"

# Compose-preview surfaces conflicts the operator needs to know about
# before saving a template. The hard ones (instance-variety collision)
# block deployment; the soft ones (protected_spec overlap) are
# resolvable but worth warning about — that's the entire UX point of
# protected_spec being declared at the catalog layer.
RSpec.describe "POST /api/v1/system/node_templates/compose_preview", type: :request do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:cat_low)  { create(:system_node_module_category, account: account, name: "low",  position: 1) }
  let(:cat_high) { create(:system_node_module_category, account: account, name: "high", position: 10) }
  let(:operator) { user_with_permissions("system.templates.update", account: account) }

  describe "protected_spec overlap detection" do
    it "warns when a higher module's file_spec covers a lower module's protected_spec entry" do
      base = create(:system_node_module, account: account, node_platform: platform,
                    category: cat_low, variety: "subscription", name: "base")
      base.update!(protected_spec: "/etc/shadow\n/etc/sudoers")

      service = create(:system_node_module, account: account, node_platform: platform,
                       category: cat_high, variety: "subscription", name: "broad-service")
      service.update!(file_spec: "/etc/**")

      post "/api/v1/system/node_templates/compose_preview",
           params: { module_ids: [ base.id, service.id ] }.to_json,
           headers: auth_headers_for(operator).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      conflicts = JSON.parse(response.body).dig("data", "conflicts")
      protected_overlap = conflicts.find { |c| c["kind"] == "protected_spec_overlap" }
      expect(protected_overlap).to be_present
      expect(protected_overlap["severity"]).to eq("warning")
      expect(protected_overlap["claimer_name"]).to eq("base")
      expect(protected_overlap["other_name"]).to eq("broad-service")
      expect(protected_overlap["paths"]).to include("/etc/shadow", "/etc/sudoers")
    end

    it "does NOT warn when no module has protected_spec" do
      a = create(:system_node_module, account: account, node_platform: platform,
                 category: cat_low, variety: "subscription", name: "a")
      a.update!(file_spec: "/etc/a/**")
      b = create(:system_node_module, account: account, node_platform: platform,
                 category: cat_high, variety: "subscription", name: "b")
      b.update!(file_spec: "/etc/b/**")

      post "/api/v1/system/node_templates/compose_preview",
           params: { module_ids: [ a.id, b.id ] }.to_json,
           headers: auth_headers_for(operator).merge("Content-Type" => "application/json")

      conflicts = JSON.parse(response.body).dig("data", "conflicts")
      expect(conflicts.select { |c| c["kind"] == "protected_spec_overlap" }).to be_empty
    end

    it "does NOT warn when paths are disjoint" do
      a = create(:system_node_module, account: account, node_platform: platform,
                 category: cat_low, variety: "subscription", name: "a")
      a.update!(protected_spec: "/etc/a/secret")
      b = create(:system_node_module, account: account, node_platform: platform,
                 category: cat_high, variety: "subscription", name: "b")
      b.update!(file_spec: "/etc/b/**")

      post "/api/v1/system/node_templates/compose_preview",
           params: { module_ids: [ a.id, b.id ] }.to_json,
           headers: auth_headers_for(operator).merge("Content-Type" => "application/json")

      conflicts = JSON.parse(response.body).dig("data", "conflicts")
      expect(conflicts.select { |c| c["kind"] == "protected_spec_overlap" }).to be_empty
    end

    it "still surfaces the hard instance_variety_collision conflict" do
      a = create(:system_node_module, account: account, node_platform: platform,
                 category: cat_high, variety: "instance", name: "inst-a")
      b = create(:system_node_module, account: account, node_platform: platform,
                 category: cat_high, variety: "instance", name: "inst-b")

      post "/api/v1/system/node_templates/compose_preview",
           params: { module_ids: [ a.id, b.id ] }.to_json,
           headers: auth_headers_for(operator).merge("Content-Type" => "application/json")

      conflicts = JSON.parse(response.body).dig("data", "conflicts")
      expect(conflicts.find { |c| c["kind"] == "instance_variety_collision" }).to be_present
    end
  end
end
