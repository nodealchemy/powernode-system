# frozen_string_literal: true

require "rails_helper"

# F6-01: locks the controller↔service result contract for the agent
# commit CLI's --push target. AgentModuleCommitService returns a Struct
# with an `ok?` member (NOT `success?`) — the controller must branch on
# `result.ok?`. A regression to `result.success?` raises NoMethodError
# and turns every commit (success or failure) into a 500.
RSpec.describe "Api::V1::System::NodeApi::ModuleVersions#create", type: :request do
  let(:account)       { create(:account) }
  let(:platform)      { create(:system_node_platform, account: account) }
  let(:category)      { create(:system_node_module_category, account: account) }
  let(:node_template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "running") }

  let!(:active_cert) do
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

  let(:node_module) do
    create(:system_node_module,
           account: account, node_platform: platform, category: category,
           name: "agent-committed-module")
  end

  # set_module resolves via current_node.node_modules (through assignments)
  let!(:assignment) do
    System::NodeModuleAssignment.create!(node: node, node_module: node_module, enabled: true, priority: 0)
  end

  let(:tar_bytes) { "fake-tar-zst-payload-#{SecureRandom.hex(8)}" }
  let(:tar_b64)   { Base64.strict_encode64(tar_bytes) }
  let(:sha256)    { Digest::SHA256.hexdigest(tar_bytes) }

  it "commits a version and returns the created payload (ok? success arm)" do
    post "/api/v1/system/node_api/modules/#{node_module.id}/versions",
         params: { tar_b64: tar_b64, sha256: sha256,
                   size_bytes: tar_bytes.bytesize, changelog: "agent build" },
         headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["success"]).to be true
    expect(body.dig("data", "version", "promotion_state")).to eq("built")
    expect(body.dig("data", "version", "id")).to be_present

    version = System::NodeModuleVersion.find(body.dig("data", "version", "id"))
    expect(version.data_checksum).to eq(sha256)
    expect(version.node_module_id).to eq(node_module.id)
  end

  it "returns 422 with the service error on checksum mismatch (ok? failure arm)" do
    post "/api/v1/system/node_api/modules/#{node_module.id}/versions",
         params: { tar_b64: tar_b64, sha256: Digest::SHA256.hexdigest("other"),
                   size_bytes: tar_bytes.bytesize },
         headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    body = JSON.parse(response.body)
    expect(body["success"]).to be false
    expect(body["error"]).to match(/sha256 mismatch/)
  end
end
