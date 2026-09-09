# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 4 — a node is served the version its OWN
# plane runs: a pinned plane's pin, a following plane's current version.
RSpec.describe "Api::V1::System::NodeApi::Modules per-environment pins", type: :request do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:staging)  { account.environments.find_by!(slug: "staging") }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform, category: category, variety: "subscription", name: "hub-backend")
  end

  def version!(n)
    create(:system_node_module_version, node_module: mod, version_number: n,
           artifacts: { "erofs" => { "oci_digest" => "sha256:#{n.to_s * 64}", "size" => 12_345_000, "oci_ref" => "ref#{n}" } })
  end

  def instance_in(environment)
    template = create(:system_node_template, account: account, node_platform: platform, environment: environment)
    node = create(:system_node, account: account, node_template: template)
    System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
    instance = create(:system_node_instance, node: node, status: "running")
    System::NodeCertificate.create!(node_instance: instance, serial: SecureRandom.hex(16), subject: "CN=#{instance.id}",
                                    not_before: 1.hour.ago, not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA")
    instance
  end

  def headers_for(instance)
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) }
  end

  it "serves a staging node its pin (nothing until promoted into) and a dev node the current version" do
    v1 = version!(1)
    v2 = version!(2)
    mod.promote_to_version!(v1)
    mod.promote_to_version!(v2)
    staging_instance = instance_in(staging)
    dev_instance = instance_in(nil)

    get "/api/v1/system/node_api/modules", headers: headers_for(staging_instance)
    expect(response).to have_http_status(:ok)
    row = JSON.parse(response.body).dig("data", "modules").find { |m| m["name"] == "hub-backend" }
    expect(row["current_version"]).to be_nil
    expect(row["has_data_file"]).to be false

    mod.promote_in_environment!(environment: staging, version: v2)
    mod.rollback_in_environment!(environment: staging, version: v1)
    get "/api/v1/system/node_api/modules", headers: headers_for(staging_instance)
    row = JSON.parse(response.body).dig("data", "modules").find { |m| m["name"] == "hub-backend" }
    expect(row["current_version"]).to eq(1)

    get "/api/v1/system/node_api/modules", headers: headers_for(dev_instance)
    row = JSON.parse(response.body).dig("data", "modules").find { |m| m["name"] == "hub-backend" }
    expect(row["current_version"]).to eq(2)

    get "/api/v1/system/node_api/modules/#{mod.id}", headers: headers_for(staging_instance)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(v1.artifact["oci_digest"])
    expect(response.body).not_to include(v2.artifact["oci_digest"])
  end
end
