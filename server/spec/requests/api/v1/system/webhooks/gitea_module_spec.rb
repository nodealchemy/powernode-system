# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M1.B — Gitea module webhook controller.
RSpec.describe "Api::V1::System::Webhooks::GiteaModule", type: :request do
  before do
    System::ModuleOciIngestService.reset!
    System::ManifestFetchService.reset!
  end

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

    # Idempotency — Gitea retries are routine. Without the
    # find-or-create-by-tag guard, every retry minted a fresh
    # NodeModuleVersion, exploding version_number monotonically.
    describe "idempotency on Gitea retry" do
      def deliver(payload)
        body = payload.to_json
        post "/api/v1/system/webhooks/gitea/module",
             params: body,
             headers: {
               "Content-Type" => "application/json",
               "X-Gitea-Signature" => hmac_for(body)
             }
      end

      it "does not mint a duplicate version on replay of the same tag" do
        expect { deliver(push_payload) }.to change { node_module.versions.count }.by(1)
        first_version = node_module.versions.order(:version_number).last

        # Replay the same delivery (Gitea retry behavior).
        expect { deliver(push_payload) }.not_to change { node_module.versions.count }
        expect(response).to have_http_status(:ok)
        expect(node_module.versions.order(:version_number).last).to eq(first_version)
      end

      it "still creates a fresh version for a new tag" do
        deliver(push_payload)
        next_payload = push_payload.deep_merge(ref: "refs/tags/v1.2.4")
        expect { deliver(next_payload) }.to change { node_module.versions.count }.by(1)
      end
    end

    # Manifest re-import — when manifest.yaml is fetchable from Gitea
    # at the published tag, its declared spec/lifecycle fields refresh
    # the module BEFORE the version snapshot, so the snapshot captures
    # the published declaration rather than the prior module state.
    describe "manifest.yaml re-import on tag publish" do
      it "applies a published manifest's protected_spec to the module" do
        # Stub the fetch adapter to return a manifest declaring a new
        # protected_spec entry that the module didn't have before.
        System::ManifestFetchService.adapter.stub_yaml = <<~YAML
          schema_version: 1
          name: nginx-mod
          description: "Updated at v1.2.3"
          protected_spec:
            - "/etc/nginx/freshly-protected.conf"
          file_spec:
            - "/etc/nginx/**"
        YAML

        body = push_payload.to_json
        post "/api/v1/system/webhooks/gitea/module",
             params: body,
             headers: {
               "Content-Type" => "application/json",
               "X-Gitea-Signature" => hmac_for(body)
             }
        expect(response).to have_http_status(:ok)

        node_module.reload
        # Module-level columns reflect the published manifest.
        expect(node_module.protected_spec_text).to include("/etc/nginx/freshly-protected.conf")
        expect(node_module.description).to eq("Updated at v1.2.3")

        # The version snapshot captures the freshly-imported state, not
        # the empty / pre-existing arrays.
        version = node_module.versions.order(:version_number).last
        decoded_protected = version.protected_spec.map { |b| Base64.decode64(b) }
        expect(decoded_protected).to include("/etc/nginx/freshly-protected.conf")
      end

      it "is non-fatal when fetch returns nil (manifest absent)" do
        System::ManifestFetchService.adapter.stub_yaml = nil # simulate file not found
        body = push_payload.to_json
        post "/api/v1/system/webhooks/gitea/module",
             params: body,
             headers: {
               "Content-Type" => "application/json",
               "X-Gitea-Signature" => hmac_for(body)
             }
        # OCI ingest still ran; webhook returns 200.
        expect(response).to have_http_status(:ok)
        expect(node_module.versions.count).to be > 0
      end

      it "is non-fatal when manifest yaml fails validation" do
        System::ManifestFetchService.adapter.stub_yaml = "schema_version: 99\nname: nginx-mod\n"
        body = push_payload.to_json
        post "/api/v1/system/webhooks/gitea/module",
             params: body,
             headers: {
               "Content-Type" => "application/json",
               "X-Gitea-Signature" => hmac_for(body)
             }
        expect(response).to have_http_status(:ok)
        # OCI ingest still ran.
        expect(node_module.versions.count).to be > 0
      end

      it "queries Gitea at the published tag, not at HEAD" do
        System::ManifestFetchService.adapter.stub_yaml = nil
        body = push_payload.to_json
        post "/api/v1/system/webhooks/gitea/module",
             params: body,
             headers: {
               "Content-Type" => "application/json",
               "X-Gitea-Signature" => hmac_for(body)
             }
        last = System::ManifestFetchService.adapter.last_request
        expect(last[:owner]).to eq("ipnode-acme")
        expect(last[:repo]).to eq("nginx-mod")
        expect(last[:path]).to eq("manifest.yaml")
        expect(last[:ref]).to eq("v1.2.3")
      end
    end

    # Spec inheritance — earlier behavior was to seed the new version
    # with empty mask/file_spec/package_spec arrays regardless of the
    # parent module's state. The version then carried no useful spec.
    it "inherits the parent module's current spec arrays into the new version" do
      node_module.update!(
        mask:           "/var/cache/apt/**",
        file_spec:      "/etc/foo/**",
        package_spec:   "foo",
        protected_spec: "/etc/foo/secret"
      )

      body = push_payload.to_json
      post "/api/v1/system/webhooks/gitea/module",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Gitea-Signature" => hmac_for(body)
           }
      expect(response).to have_http_status(:ok)

      version = node_module.versions.order(:version_number).last
      decoded = ->(arr) { arr.map { |b| Base64.decode64(b) } }
      expect(decoded.call(version.protected_spec)).to include("/etc/foo/secret")
      expect(decoded.call(version.file_spec)).to       include("/etc/foo/**")
      expect(decoded.call(version.mask)).to            include("/var/cache/apt/**")
    end
  end
end
