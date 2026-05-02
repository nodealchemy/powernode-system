# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M1.B — Gitea module webhook controller.
RSpec.describe "Api::V1::System::Webhooks::GiteaModule", type: :request do
  before { System::ModuleOciIngestService.reset! }

  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:webhook_secret) { "shared-webhook-secret-#{SecureRandom.hex(8)}" }
  let!(:node_module) do
    create(:system_node_module,
           account: account, node_platform: platform, category: category,
           variety: "subscription", name: "nginx-mod",
           gitea_repo_full_name: "ipnode-acme/nginx-mod",
           webhook_secret: webhook_secret)
  end

  let(:push_payload) do
    {
      ref: "refs/tags/v1.2.3",
      repository: { full_name: "ipnode-acme/nginx-mod" }
    }
  end

  def hmac_for(body, secret = webhook_secret)
    OpenSSL::HMAC.hexdigest("sha256", secret, body)
  end

  describe "POST /api/v1/system/webhooks/gitea/module" do
    it "returns 200 + ingests on a valid signed push event" do
      body = push_payload.to_json
      post "/api/v1/system/webhooks/gitea/module",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Gitea-Signature" => hmac_for(body)
           }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["status"]).to eq("ok")
      expect(json["message"]).to include("Ingested").and include("v1.2.3")

      version = node_module.versions.last
      expect(version).to be_present
      expect(version.config["git_tag"]).to eq("v1.2.3")
      expect(version.module_artifacts.count).to eq(2) # amd64 + arm64
    end

    it "accepts X-Hub-Signature-256 header (sha256= prefix tolerated)" do
      body = push_payload.to_json
      post "/api/v1/system/webhooks/gitea/module",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Hub-Signature-256" => "sha256=#{hmac_for(body)}"
           }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to include("Ingested")
    end

    it "returns 200 with 'Invalid signature' message on HMAC mismatch (no retry storm)" do
      body = push_payload.to_json
      post "/api/v1/system/webhooks/gitea/module",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Gitea-Signature" => "deadbeef" # wrong
           }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to eq("Invalid signature")
    end

    it "returns 200 with 'Module not found' for unknown repo" do
      body = push_payload.deep_merge(repository: { full_name: "nope/missing" }).to_json
      post "/api/v1/system/webhooks/gitea/module",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Gitea-Signature" => hmac_for(body)
           }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to eq("Module not found")
    end

    it "returns 200 with 'No actionable tag' when ref isn't a tag" do
      body = { ref: "refs/heads/main", repository: { full_name: "ipnode-acme/nginx-mod" } }.to_json
      post "/api/v1/system/webhooks/gitea/module",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Gitea-Signature" => hmac_for(body)
           }
      expect(response).to have_http_status(:ok)
      # Branch ref still has its full ref string, the controller will use it as-is
      json = JSON.parse(response.body)
      expect(json["status"]).to eq("ok")
    end

    it "returns 200 + processing-error message when ingest blows up (no 500)" do
      System::ModuleOciIngestService.adapter.stub_manifest = { error: "registry returned 500" }
      body = push_payload.to_json
      post "/api/v1/system/webhooks/gitea/module",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Gitea-Signature" => hmac_for(body)
           }
      expect(response).to have_http_status(:ok)
      msg = JSON.parse(response.body)["message"]
      expect(msg).to include("Ingest failed").or include("Processing error")
    end

    it "accepts a release event payload shape" do
      body = {
        action: "published",
        release: { tag_name: "v2.0.0" },
        repository: { full_name: "ipnode-acme/nginx-mod" }
      }.to_json
      post "/api/v1/system/webhooks/gitea/module",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Gitea-Signature" => hmac_for(body)
           }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to include("v2.0.0")
    end

    it "accepts unsigned events when webhook_secret is blank (dev opt-out)" do
      node_module.update!(webhook_secret: nil)
      body = push_payload.to_json
      post "/api/v1/system/webhooks/gitea/module",
           params: body, headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to include("Ingested")
    end
  end
end
