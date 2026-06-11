# frozen_string_literal: true

require "rails_helper"

# Audit F5-03 — the puppet surface (per-instance manifest generation through
# the NodeModuleAssignment -> ModulePuppetAssignment chain) had zero
# request-spec coverage.
RSpec.describe "Api::V1::System::NodeApi::Puppet#manifest", type: :request do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, node: node, status: "running") }

  let!(:cert) do
    System::NodeCertificate.create!(
      node_instance: instance,
      serial:         SecureRandom.hex(16),
      subject:        "CN=#{instance.id}",
      not_before:     1.hour.ago,
      not_after:      90.days.from_now,
      issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:headers) do
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) }
  end

  it "rejects unauthenticated requests" do
    get "/api/v1/system/node_api/puppet/manifest"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns an empty-but-valid manifest when no puppet modules are assigned" do
    get "/api/v1/system/node_api/puppet/manifest", headers: headers

    expect(response).to have_http_status(:ok)
    data = JSON.parse(response.body)["data"]
    expect(data["manifest"]).to include("Puppet manifest for instance")
    expect(data["modules_count"]).to eq(0)
    expect(data["resources_count"]).to eq(0)
  end

  it "renders modules + resources reachable through this node's module assignments" do
    node_module = create(:system_node_module, account: account, node_platform: platform,
                         category: category, name: "web-mod")
    System::NodeModuleAssignment.create!(node: node, node_module: node_module,
                                         enabled: true, priority: 0)
    puppet_module = create(:system_puppet_module, account: account)
    create(:system_module_puppet_assignment, node_module: node_module,
           puppet_module: puppet_module)
    resource = create(:system_puppet_resource, puppet_module: puppet_module)

    get "/api/v1/system/node_api/puppet/manifest", headers: headers

    expect(response).to have_http_status(:ok)
    data = JSON.parse(response.body)["data"]
    expect(data["modules_count"]).to eq(1)
    expect(data["resources_count"]).to eq(1)
    expect(data["manifest"]).to include(puppet_module.name)
    expect(data["manifest"]).to include(resource.title)
  end

  it "excludes puppet modules attached to OTHER nodes' modules" do
    foreign_node = create(:system_node, account: account, node_template: template)
    foreign_mod = create(:system_node_module, account: account, node_platform: platform,
                         category: category, name: "foreign-mod")
    System::NodeModuleAssignment.create!(node: foreign_node, node_module: foreign_mod,
                                         enabled: true, priority: 0)
    foreign_puppet = create(:system_puppet_module, account: account)
    create(:system_module_puppet_assignment, node_module: foreign_mod,
           puppet_module: foreign_puppet)

    get "/api/v1/system/node_api/puppet/manifest", headers: headers

    data = JSON.parse(response.body)["data"]
    expect(data["modules_count"]).to eq(0)
    expect(data["manifest"]).not_to include(foreign_puppet.name)
  end
end
