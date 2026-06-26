# frozen_string_literal: true

require "rails_helper"

# Inbound CI callback from build-package-module.yaml. Per the platform
# webhook-receiver rule, PROCESSING errors MUST return 200/202 (never 500)
# so the CI workflow records the failure without retry-storming. AUTH /
# signature rejections still return 401 — those are not processing errors.
RSpec.describe "Api::V1::System::Webhooks::PackageBuild", type: :request do
  let(:closure_id) { "closure-#{SecureRandom.hex(6)}" }

  let(:payload) do
    {
      closure_id:   closure_id,
      architecture: "amd64",
      modules: [
        { module_id: SecureRandom.uuid, file_spec: ["/usr/bin/foo"] }
      ]
    }
  end

  # Mirror the controller's signing scheme exactly: HMAC-SHA256 over the
  # closure_id (NOT the raw body) using the build-package HMAC key.
  def sign(cid)
    key = ENV.fetch("POWERNODE_PACKAGE_BUILD_HMAC_KEY", "dev-package-build-secret")
    OpenSSL::HMAC.hexdigest("SHA256", key, cid)
  end

  def deliver(body:, signature:)
    post "/api/v1/system/webhooks/package_build",
         params: body,
         headers: {
           "Content-Type" => "application/json",
           "X-Powernode-Signature" => signature
         }
  end

  describe "POST /api/v1/system/webhooks/package_build" do
    it "returns 202 on a valid signed payload that processes cleanly" do
      result = ::System::PackageBuildWebhookService::Result.new(
        success: true, artifacts_created: 1, versions_created: 1, modules_updated: 1, errors: []
      )
      allow(::System::PackageBuildWebhookService).to receive(:call).and_return(result)

      body = payload.to_json
      deliver(body: body, signature: sign(closure_id))

      expect(response).to have_http_status(:accepted)
      json = JSON.parse(response.body)
      expect(json["data"]["artifacts_created"]).to eq(1)
    end

    # The regression guard. A non-WebhookError processing exception must NOT
    # fall through to the global rescue_from StandardError -> 500, which would
    # trigger CI retry storms. It must be caught and acked with 202.
    it "returns 202 (never 500) when the processing service raises a generic StandardError" do
      allow(::System::PackageBuildWebhookService)
        .to receive(:call).and_raise(StandardError, "unexpected processing boom")

      body = payload.to_json
      deliver(body: body, signature: sign(closure_id))

      expect(response).to have_http_status(:accepted)
      json = JSON.parse(response.body)
      expect(json["data"]["ok"]).to be false
    end

    it "still rejects a bad signature with 401 (auth failures are NOT swallowed)" do
      # Service must never even be reached on an auth rejection.
      expect(::System::PackageBuildWebhookService).not_to receive(:call)

      body = payload.to_json
      deliver(body: body, signature: "deadbeef")

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 422 on a WebhookError (validation surfaced, not retried as 500)" do
      allow(::System::PackageBuildWebhookService)
        .to receive(:call).and_raise(::System::PackageBuildWebhookService::WebhookError, "missing modules")

      body = payload.to_json
      deliver(body: body, signature: sign(closure_id))

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "never returns 500 on unparseable JSON input" do
      # text/plain so Rails' built-in JSON parser doesn't reject the body
      # before the controller sees it. An unparseable body has no readable
      # closure_id, so verify_signature fails -> rejected at the auth gate
      # (401). The point: garbage input is never a 500.
      body = "this is not json"
      post "/api/v1/system/webhooks/package_build",
           params: body,
           headers: {
             "Content-Type" => "text/plain",
             "X-Powernode-Signature" => "anything"
           }

      expect(response).to have_http_status(:unauthorized)
      expect(response.status).not_to eq(500)
    end
  end
end
