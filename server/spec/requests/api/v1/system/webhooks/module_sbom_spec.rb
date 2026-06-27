# frozen_string_literal: true

require "rails_helper"

# Comprehensive stabilization sweep Phase 10.2 — SBOM ingestion endpoint.
# Mirrors the GiteaModule webhook contract: HMAC over body via per-module
# secret, ALWAYS returns 200 (no retry storms).
RSpec.describe "Api::V1::System::Webhooks::ModuleSbom", type: :request do
  let(:account) { create(:account) }
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
  let!(:version) do
    create(:system_node_module_version,
           node_module: node_module, version_number: 1,
           config: { "git_tag" => "v1.2.3" })
  end
  let!(:artifact) do
    System::ModuleArtifact.create!(
      node_module_version: version,
      oci_ref: "registry.example.com/ipnode-acme/nginx-mod:v1.2.3-amd64",
      oci_digest: "sha256:#{SecureRandom.hex(32)}",
      media_type: "application/vnd.powernode.module.v1",
      architecture: "amd64",
      size_bytes: 1024,
      built_at: Time.current
    )
  end

  let(:cyclonedx_payload) do
    {
      "bomFormat" => "CycloneDX",
      "specVersion" => "1.5",
      "components" => [
        { "name" => "openssl", "version" => "3.0.7", "purl" => "pkg:deb/debian/openssl@3.0.7" },
        { "name" => "rails",   "version" => "8.1.0", "purl" => "pkg:gem/rails@8.1.0" }
      ]
    }
  end

  def build_body(overrides = {})
    {
      module_id: node_module.id,
      tag: "v1.2.3",
      architecture: "amd64",
      sbom: cyclonedx_payload
    }.merge(overrides).to_json
  end

  def hmac_for(body, secret = webhook_secret)
    OpenSSL::HMAC.hexdigest("sha256", secret, body)
  end

  describe "POST /api/v1/system/webhooks/gitea/module_sbom" do
    it "ingests a valid signed SBOM and updates artifact columns" do
      body = build_body
      post "/api/v1/system/webhooks/gitea/module_sbom",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Gitea-Signature" => hmac_for(body)
           }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["status"]).to eq("ok")
      expect(json["message"]).to include("SBOM ingested").and include("packages=2")

      artifact.reload
      expect(artifact.sbom_packages_count).to eq(2)
      expect(artifact.sbom_packages_synced_at).to be_within(5.seconds).of(Time.current)
      expect(artifact.sbom_packages.map { |p| p["name"] }).to contain_exactly("openssl", "rails")
      expect(artifact.sbom_packages.first["ecosystem"]).to eq("deb")
    end

    it "accepts X-Hub-Signature-256 header (sha256= prefix tolerated)" do
      body = build_body
      post "/api/v1/system/webhooks/gitea/module_sbom",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Hub-Signature-256" => "sha256=#{hmac_for(body)}"
           }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to include("SBOM ingested")
    end

    it "normalizes refs/tags/ prefix on the tag" do
      body = build_body(tag: "refs/tags/v1.2.3")
      post "/api/v1/system/webhooks/gitea/module_sbom",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Gitea-Signature" => hmac_for(body)
           }

      expect(JSON.parse(response.body)["message"]).to include("SBOM ingested")
      expect(artifact.reload.sbom_packages_count).to eq(2)
    end

    it "returns 200 with 'Invalid signature' on HMAC mismatch (no retry storm)" do
      body = build_body
      post "/api/v1/system/webhooks/gitea/module_sbom",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Gitea-Signature" => "deadbeef"
           }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to eq("Invalid signature")
      expect(artifact.reload.sbom_packages_count).to eq(0) # untouched
    end

    it "accepts an unsigned SBOM when webhook_secret is blank (dev opt-out, fail-open unchanged)" do
      node_module.update!(webhook_secret: nil)
      body = build_body
      post "/api/v1/system/webhooks/gitea/module_sbom",
           params: body,
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to include("SBOM ingested")
      expect(artifact.reload.sbom_packages_count).to eq(2)
    end

    it "returns 200 with 'Module not found' for unknown module_id" do
      body = build_body(module_id: SecureRandom.uuid)
      post "/api/v1/system/webhooks/gitea/module_sbom",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Gitea-Signature" => hmac_for(body)
           }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to eq("Module not found")
    end

    it "returns 200 with 'Artifact not found' when no version matches the tag" do
      body = build_body(tag: "v9.9.9")
      post "/api/v1/system/webhooks/gitea/module_sbom",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Gitea-Signature" => hmac_for(body)
           }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to include("Artifact not found")
    end

    it "returns 200 with 'Artifact not found' when no artifact for the architecture" do
      body = build_body(architecture: "arm64")
      post "/api/v1/system/webhooks/gitea/module_sbom",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Gitea-Signature" => hmac_for(body)
           }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to include("Artifact not found")
    end

    it "returns 200 with 'Empty body' when body is blank" do
      post "/api/v1/system/webhooks/gitea/module_sbom",
           params: "",
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to eq("Empty body")
    end

    it "is idempotent on identical re-ingestion (data stable, synced_at advances)" do
      body = build_body
      headers = { "Content-Type" => "application/json", "X-Gitea-Signature" => hmac_for(body) }

      post "/api/v1/system/webhooks/gitea/module_sbom", params: body, headers: headers
      first_data = artifact.reload.sbom_packages_data.dup
      first_synced_at = artifact.sbom_packages_synced_at

      travel_to(2.seconds.from_now) do
        post "/api/v1/system/webhooks/gitea/module_sbom", params: body, headers: headers
      end

      artifact.reload
      expect(artifact.sbom_packages_data).to eq(first_data)
      expect(artifact.sbom_packages_count).to eq(2)
      expect(artifact.sbom_packages_synced_at).to be > first_synced_at
    end

    it "reports truncation when SBOM exceeds MAX_PACKAGES" do
      large_components = (System::Sbom::CycloneDxParser::MAX_PACKAGES + 10).times.map do |i|
        { "name" => "pkg-#{i}", "version" => "1.0" }
      end
      body = build_body(sbom: { "bomFormat" => "CycloneDX", "components" => large_components })

      post "/api/v1/system/webhooks/gitea/module_sbom",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Gitea-Signature" => hmac_for(body)
           }

      expect(JSON.parse(response.body)["message"]).to include("truncated=true")
      expect(artifact.reload.sbom_packages_count).to eq(System::Sbom::CycloneDxParser::MAX_PACKAGES)
    end

    it "rejects (with 200 + 'Empty body') when JSON is malformed" do
      post "/api/v1/system/webhooks/gitea/module_sbom",
           params: "{ not valid json",
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to eq("Empty body")
    end

    # IMP-7c61c2db3bef / D9 step-2 — fail-closed enforcement. With
    # POWERNODE_MODULE_WEBHOOK_ENFORCE=true the SBOM receiver verifies the
    # body HMAC against the DERIVED per-module secret (NOT the unpopulated
    # node_module.webhook_secret column) and rejects anything unverifiable.
    # Still ALWAYS 200 (no retry storms).
    describe "POWERNODE_MODULE_WEBHOOK_ENFORCE=true (derived-secret fail-closed)" do
      around do |ex|
        prev = ENV["POWERNODE_MODULE_WEBHOOK_ENFORCE"]
        ENV["POWERNODE_MODULE_WEBHOOK_ENFORCE"] = "true"
        ex.run
      ensure
        ENV["POWERNODE_MODULE_WEBHOOK_ENFORCE"] = prev
      end

      def derived_secret
        ::System::ModuleBuildDispatchService.module_webhook_secret_for(node_module.id)
      end

      def deliver(body, signature: nil)
        headers = { "Content-Type" => "application/json" }
        headers["X-Gitea-Signature"] = signature if signature
        post "/api/v1/system/webhooks/gitea/module_sbom", params: body, headers: headers
      end

      context "dev/test (dev-fallback server secret present)" do
        it "ACCEPTS an SBOM signed with the derived secret" do
          body = build_body
          deliver(body, signature: hmac_for(body, derived_secret))
          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["message"]).to include("SBOM ingested")
          expect(artifact.reload.sbom_packages_count).to eq(2)
        end

        it "REJECTS a wrong signature (200 'Invalid signature', untouched artifact)" do
          body = build_body
          deliver(body, signature: "deadbeef")
          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["message"]).to eq("Invalid signature")
          expect(artifact.reload.sbom_packages_count).to eq(0)
        end

        it "REJECTS an UNSIGNED SBOM — no more dev accept-all opt-out" do
          body = build_body
          deliver(body) # no signature header
          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["message"]).to eq("Invalid signature")
          expect(artifact.reload.sbom_packages_count).to eq(0)
        end
      end

      context "production with SERVER_SECRET_ENV set" do
        around do |ex|
          prev = ENV["POWERNODE_PACKAGE_BUILD_HMAC_KEY"]
          ENV["POWERNODE_PACKAGE_BUILD_HMAC_KEY"] = "prod-root-secret-xyz"
          ex.run
        ensure
          ENV["POWERNODE_PACKAGE_BUILD_HMAC_KEY"] = prev
        end

        it "ACCEPTS an SBOM signed with the prod-rooted derived secret" do
          allow(Rails.env).to receive(:production?).and_return(true)
          body = build_body
          deliver(body, signature: hmac_for(body, derived_secret))
          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["message"]).to include("SBOM ingested")
        end
      end

      context "production with SERVER_SECRET_ENV unset (fail-closed)" do
        it "REJECTS — no derivable secret, never 500" do
          allow(::System::ModuleBuildDispatchService).to receive(:server_secret).and_return(nil)
          body = build_body
          deliver(body, signature: "sha256=#{OpenSSL::HMAC.hexdigest('sha256', 'anything', body)}")
          expect(response).to have_http_status(:ok)
          expect(response.status).not_to eq(500)
          expect(JSON.parse(response.body)["message"]).to eq("Invalid signature")
          expect(artifact.reload.sbom_packages_count).to eq(0)
        end
      end
    end
  end
end
