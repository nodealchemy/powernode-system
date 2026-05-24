# frozen_string_literal: true

require "rails_helper"

# CI-direct webhook receiver. The build-platform-modules workflow
# POSTs here after each `oras push + cosign sign` with the module
# slug + tag + artifact descriptor + the raw manifest YAML so the
# controller can re-sync NodeModule + ModuleService rows in lockstep
# with the erofs blob it just published.
RSpec.describe "POST /api/v1/system/module_publications", type: :request do
  let(:account)      { create(:account) }
  let(:platform)     { create(:system_node_platform, account: account) }
  let(:category)     { create(:system_node_module_category, account: account) }
  let(:ci_token)     { "ci-tok-#{SecureRandom.hex(8)}" }
  let(:bearer)       { { "Authorization" => "Bearer #{ci_token}", "Content-Type" => "application/json" } }

  let!(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
                                category: category, variety: "subscription",
                                name: "powernode-hub-backend",
                                gitea_repo_full_name: "powernode/powernode-hub-backend",
                                file_spec: [ Base64.strict_encode64("/opt/powernode-rails") ])
  end

  let(:manifest_yaml) do
    <<~YAML
      schema_version: 1
      name: powernode-hub-backend
      display_name: Powernode Hub Backend
      file_spec:
        - /opt/powernode/server/**
      mask:
        - /opt/powernode/server/tmp/***
      services:
        - name: rails
          start_command: "/usr/local/bin/rails-start.sh"
          restart_policy: always
          user: root
          working_directory: /opt/powernode/server
          env:
            RAILS_ENV: production
      reboot_required: false
    YAML
  end

  let(:artifacts) do
    {
      erofs: {
        oci_ref:       "git.ipnode.org/powernode/powernode-hub-backend:abc1234",
        fsverity_root: "sha256:" + ("0" * 64),
        size:          12_345_678,
        media_type:    "application/vnd.powernode.erofs"
      }
    }
  end

  let(:base_body) do
    {
      module_name:       "powernode-hub-backend",
      tag:               "abc1234",
      manifest_yaml_b64: Base64.strict_encode64(manifest_yaml),
      artifacts:         artifacts
    }
  end

  before do
    ENV["POWERNODE_CI_WORKER_TOKEN"] = ci_token
    # Layer-digest fetch hits the registry; skip the network hop in unit
    # tests. The behavior under success is covered by the agent's pull
    # path; here we only care that the controller calls it and merges
    # the response cleanly. nil = "couldn't fetch" path.
    allow_any_instance_of(Api::V1::System::ModulePublicationsController)
      .to receive(:fetch_oci_layer_digest).and_return(nil)
  end

  after { ENV.delete("POWERNODE_CI_WORKER_TOKEN") }

  it "rejects requests without the CI bearer" do
    post "/api/v1/system/module_publications", params: base_body.to_json,
         headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "creates a NodeModuleVersion and applies the manifest to the parent NodeModule" do
    expect {
      post "/api/v1/system/module_publications", params: base_body.to_json, headers: bearer
    }.to change { node_module.versions.count }.by(1)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body).fetch("data")
    expect(body["manifest_import_error"]).to be_nil, "import error: #{body['manifest_import_error']}"
    expect(body["manifest_applied"]).to be(true)

    node_module.reload
    decoded = Array(node_module.file_spec).map { |s| Base64.strict_decode64(s) }
    expect(decoded).to eq([ "/opt/powernode/server/**" ])

    svc = node_module.module_services.find_by(name: "rails")
    expect(svc).to be_present
    expect(svc.start_command).to eq("/usr/local/bin/rails-start.sh")
    expect(svc.working_directory).to eq("/opt/powernode/server")
  end

  it "still creates a version row when manifest_yaml_b64 is absent (backwards compat)" do
    body = base_body.except(:manifest_yaml_b64)
    expect {
      post "/api/v1/system/module_publications", params: body.to_json, headers: bearer
    }.to change { node_module.versions.count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("data", "manifest_applied")).to be(true) # nil-encoded as success: nothing to apply
    # NodeModule.file_spec unchanged
    decoded = Array(node_module.reload.file_spec).map { |s| Base64.strict_decode64(s) }
    expect(decoded).to eq([ "/opt/powernode-rails" ])
  end

  it "surfaces manifest_import_error when manifest_yaml_b64 is malformed" do
    body = base_body.merge(manifest_yaml_b64: "@@@not-base64@@@")
    post "/api/v1/system/module_publications", params: body.to_json, headers: bearer

    expect(response).to have_http_status(:ok)
    data = JSON.parse(response.body).fetch("data")
    expect(data["manifest_applied"]).to be(false)
    expect(data["manifest_import_error"]).to include("not valid base64")
  end
end
