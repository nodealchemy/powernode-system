# frozen_string_literal: true

require "rails_helper"

# Worker → server callback that runs the long-pole module publication
# work (manifest fetch + version snapshot + OCI ingest + skill register
# + fleet event emit). The webhook receiver enqueues
# System::ProcessModulePublicationJob; that job calls this endpoint.
RSpec.describe "POST /api/v1/system/worker_api/module_publications/process", type: :request do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:plain_token) { "wrk-tok-#{SecureRandom.hex(8)}" }
  let!(:worker) do
    w = create(:worker, account: account, status: "active")
    w.update_columns(token_digest: Digest::SHA256.hexdigest(plain_token))
    w
  end
  let(:headers) { { "X-Worker-Token" => plain_token, "Content-Type" => "application/json" } }
  let!(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "demo-mod",
           gitea_repo_full_name: "ipnode-acme/demo-mod")
  end

  before do
    allow_any_instance_of(Worker).to receive(:has_permission?)
      .with("system.modules.update").and_return(true)
    System::ModuleOciIngestService.reset!
    System::ManifestFetchService.reset!
  end

  it "looks up the module, runs the processor, and returns the resulting version_id" do
    post "/api/v1/system/worker_api/module_publications/process",
         params: { node_module_id: node_module.id, tag: "v1.0.0" }.to_json,
         headers: headers
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body).fetch("data")
    expect(body["version_number"]).to eq(1)
    expect(body["arches"]).to include("amd64")
  end

  it "404s when the module doesn't exist" do
    post "/api/v1/system/worker_api/module_publications/process",
         params: { node_module_id: SecureRandom.uuid, tag: "v1.0.0" }.to_json,
         headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "400s when tag is missing" do
    post "/api/v1/system/worker_api/module_publications/process",
         params: { node_module_id: node_module.id }.to_json,
         headers: headers
    expect(response).to have_http_status(:bad_request)
  end

  it "422s when ingest fails (Sidekiq treats as retryable)" do
    System::ModuleOciIngestService.adapter.stub_manifest = { error: "registry returned 502" }
    post "/api/v1/system/worker_api/module_publications/process",
         params: { node_module_id: node_module.id, tag: "v1.0.0" }.to_json,
         headers: headers
    # Per the controller comment: 422 is the right shape — Sidekiq's retry
    # middleware treats it as retryable, but the dead queue is more useful
    # than silent loss for genuinely-broken inputs.
    expect(response.status).to eq(422)
    expect(JSON.parse(response.body)["error"]).to include("502")
  end

  it "rejects unauthenticated requests (no worker token)" do
    post "/api/v1/system/worker_api/module_publications/process",
         params: { node_module_id: node_module.id, tag: "v1.0.0" }.to_json,
         headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end
end
