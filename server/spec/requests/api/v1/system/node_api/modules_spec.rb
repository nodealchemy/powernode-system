# frozen_string_literal: true

require "rails_helper"

# Locks the on-node modules endpoint against the dependant-children
# regression: dependants have parent_module_id + node_id but no
# NodeModuleAssignment row, so the legacy query (assignments only)
# silently dropped them from the agent's view.
RSpec.describe "Api::V1::System::NodeApi::Modules#index", type: :request do
  let(:account)       { create(:account) }
  let(:platform)      { create(:system_node_platform, account: account) }
  let(:category)      { create(:system_node_module_category, account: account, name: "Base") }
  let(:node_template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "running") }
  let(:auth_token) do
    ::Security::JwtService.encode({
      sub:     instance.id,
      type:    "instance",
      version: ::Security::JwtService::CURRENT_TOKEN_VERSION
    })
  end
  let(:headers) { { "X-Instance-Token" => auth_token } }

  let(:base_module) do
    create(:system_node_module,
           account: account, node_platform: platform, category: category,
           variety: "subscription", name: "nginx-base", priority: 5)
  end
  let!(:assignment) do
    System::NodeModuleAssignment.create!(node: node, node_module: base_module, enabled: true, priority: 0)
  end

  describe "agent view" do
    it "returns base modules attached via NodeModuleAssignment" do
      get "/api/v1/system/node_api/modules", headers: headers
      expect(response).to have_http_status(:ok)
      names = JSON.parse(response.body).dig("data", "modules").map { |m| m["name"] }
      expect(names).to include("nginx-base")
    end

    it "ALSO returns dependant children scoped via parent_module + node FK" do
      child = assignment.create_dependant!
      expect(child.parent_module).to eq(base_module)
      expect(child.node).to eq(node)
      expect(System::NodeModuleAssignment.where(node_module: child)).to be_empty

      get "/api/v1/system/node_api/modules", headers: headers
      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body).dig("data", "modules").map { |m| m["id"] }
      expect(ids).to include(base_module.id, child.id)
    end

    it "returns the inherited file_spec on a dependant child via show" do
      base_module.update!(dependency_spec: "/etc/inherited/**")
      child = assignment.create_dependant!

      get "/api/v1/system/node_api/modules/#{child.id}", headers: headers
      expect(response).to have_http_status(:ok)
      payload = JSON.parse(response.body).dig("data", "module")
      decoded = payload["file_spec"].map { |b| Base64.decode64(b) }
      expect(decoded).to include("/etc/inherited/**")
    end

    it "respects the dependant child's enabled flag" do
      child = assignment.create_dependant!
      child.update!(enabled: false)

      get "/api/v1/system/node_api/modules", headers: headers
      ids = JSON.parse(response.body).dig("data", "modules").map { |m| m["id"] }
      expect(ids).not_to include(child.id)
    end

    it "does NOT return dependant children of OTHER nodes" do
      other_node = create(:system_node, account: account, node_template: node_template)
      other_assignment = System::NodeModuleAssignment.create!(
        node: other_node, node_module: base_module, enabled: true, priority: 0
      )
      other_child = other_assignment.create_dependant!

      get "/api/v1/system/node_api/modules", headers: headers
      ids = JSON.parse(response.body).dig("data", "modules").map { |m| m["id"] }
      expect(ids).not_to include(other_child.id)
    end
  end
end
