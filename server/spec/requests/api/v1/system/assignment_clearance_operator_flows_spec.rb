# frozen_string_literal: true

require "rails_helper"

# IMP-9f4e162d9ed1 — the two operator REST doors among the five unassign flows:
# POST nodes/:id/apply_template (purge_stale) and POST
# node_module_assignments/:id/disable. The MCP doors are covered in
# spec/models/system/assignment_clearance_flows_spec.rb.
RSpec.describe "Operator unassign flows record a clearance", type: :request do
  let(:account)  { create(:account) }
  let(:user)     { user_with_permissions("system.nodes.read", "system.modules.update", account: account) }
  let(:headers)  { auth_headers_for(user).merge("Content-Type" => "application/json") }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, name: "cat-#{SecureRandom.hex(3)}") }
  let(:template) { create(:system_node_template, account: account, node_platform: platform, name: "t-#{SecureRandom.hex(3)}") }
  let(:node)     { create(:system_node, account: account, node_template: template, name: "n-#{SecureRandom.hex(3)}") }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform, category: category,
           variety: "subscription", name: "m-#{SecureRandom.hex(3)}")
  end

  it "E2: apply_template with purge_stale after the template lost its module clears the module" do
    join = System::TemplateModule.create!(node_template: template, node_module: mod, enabled: true)
    System::TemplateApplyService.new(node).apply!
    join.update!(enabled: false)

    post "/api/v1/system/nodes/#{node.id}/apply_template", params: { purge_stale: true }.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    expect(System::NodeAssignmentClearance.where(node_id: node.id).pluck(:node_module_id)).to eq([ mod.id ])
  end

  it "E2: apply_template WITHOUT purge_stale clears nothing" do
    join = System::TemplateModule.create!(node_template: template, node_module: mod, enabled: true)
    System::TemplateApplyService.new(node).apply!
    join.update!(enabled: false)

    post "/api/v1/system/nodes/#{node.id}/apply_template", headers: headers

    expect(System::NodeAssignmentClearance.where(node_id: node.id)).to be_empty
  end

  it "E4: the disable endpoint clears the module, the enable endpoint revokes it" do
    assignment = create(:system_node_module_assignment, node: node, node_module: mod, enabled: true)

    post "/api/v1/system/node_module_assignments/#{assignment.id}/disable", headers: headers
    expect(response).to have_http_status(:ok)
    expect(System::NodeAssignmentClearance.where(node_id: node.id).pluck(:node_module_id)).to eq([ mod.id ])

    post "/api/v1/system/node_module_assignments/#{assignment.id}/enable", headers: headers
    expect(response).to have_http_status(:ok)
    expect(System::NodeAssignmentClearance.where(node_id: node.id)).to be_empty
  end
end
