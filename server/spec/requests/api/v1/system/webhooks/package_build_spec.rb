# frozen_string_literal: true

require "rails_helper"

# Inbound CI callback from build-package-module.yaml. Per the platform
# webhook-receiver rule, PROCESSING errors MUST return 200/202 (never 500)
# so the CI workflow records the failure without retry-storming. AUTH /
# signature rejections still return 401 — those are not processing errors.
#
# Security: the signature authenticates the RAW BODY (not just the
# closure_id), so artifact metadata (oci_ref, versions) can't be forged
# with a captured signature. Mirrors the disk-image webhook scheme:
# HMAC-SHA256 over request.raw_post with a per-closure secret derived from
# a server-side secret, header format "sha256=<hex>".
RSpec.describe "Api::V1::System::Webhooks::PackageBuild", type: :request do
  let(:closure_id) { "closure-#{SecureRandom.hex(6)}" }

  let(:payload) do
    {
      closure_id:   closure_id,
      architecture: "amd64",
      modules: [
        { module_id: SecureRandom.uuid, oci_ref: "registry.example/mod:good", file_spec: ["/usr/bin/foo"] }
      ]
    }
  end

  # Sign the EXACT body bytes with the per-closure secret, header form
  # "sha256=<hex>" — mirrors build-package-module.yaml's Send-completion-
  # webhook step (and the proven build-disk-image.yaml sender).
  def sign_body(body)
    cid    = JSON.parse(body)["closure_id"]
    secret = ::System::ModuleBuildDispatchService.webhook_secret_for(cid)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
  end

  # The OLD (vulnerable) scheme signed the closure_id alone, i.e. the
  # accepted signature was HMAC(server_secret, closure_id) — which is exactly
  # the per-closure secret. Reproduce that captured value so we can prove it
  # can no longer authorize a forged body for that same closure_id.
  def legacy_sign(cid)
    ::System::ModuleBuildDispatchService.webhook_secret_for(cid)
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
    it "returns 202 on a valid raw-body signature that processes cleanly" do
      result = ::System::PackageBuildWebhookService::Result.new(
        success: true, artifacts_created: 1, versions_created: 1, modules_updated: 1, errors: []
      )
      allow(::System::PackageBuildWebhookService).to receive(:call).and_return(result)

      body = payload.to_json
      deliver(body: body, signature: sign_body(body))

      expect(response).to have_http_status(:accepted)
      json = JSON.parse(response.body)
      expect(json["data"]["artifacts_created"]).to eq(1)
    end

    # CORE SECURITY GUARD. An attacker who captures a valid (closure_id,
    # signature) pair must NOT be able to POST a forged body for that
    # closure_id (e.g. swapping oci_ref to an attacker-controlled image).
    # The signature now covers the body, so a tampered body is rejected.
    it "rejects a forged body even with a signature valid for the original closure_id" do
      # Stub success so the PRE-fix path (which accepted forged bodies)
      # deterministically returns 202 — making the RED state unambiguous.
      result = ::System::PackageBuildWebhookService::Result.new(
        success: true, artifacts_created: 9, versions_created: 9, modules_updated: 9, errors: []
      )
      allow(::System::PackageBuildWebhookService).to receive(:call).and_return(result)

      legit_body   = payload.to_json
      captured_sig = legacy_sign(closure_id) # what the old scheme authorized

      forged = JSON.parse(legit_body)
      forged["modules"] = [
        { "module_id" => SecureRandom.uuid, "oci_ref" => "evil.example/pwn:latest" }
      ]
      forged_body = forged.to_json # SAME closure_id, tampered artifact metadata

      deliver(body: forged_body, signature: captured_sig)

      expect(response).to have_http_status(:unauthorized)
    end

    # The regression guard. A non-WebhookError processing exception must NOT
    # fall through to the global rescue_from StandardError -> 500, which would
    # trigger CI retry storms. It must be caught and acked with 202.
    it "returns 202 (never 500) when the processing service raises a generic StandardError" do
      allow(::System::PackageBuildWebhookService)
        .to receive(:call).and_raise(StandardError, "unexpected processing boom")

      body = payload.to_json
      deliver(body: body, signature: sign_body(body))

      expect(response).to have_http_status(:accepted)
      json = JSON.parse(response.body)
      expect(json["data"]["ok"]).to be false
    end

    it "still rejects a bad signature with 401 (auth failures are NOT swallowed)" do
      # Service must never even be reached on an auth rejection.
      expect(::System::PackageBuildWebhookService).not_to receive(:call)

      body = payload.to_json
      deliver(body: body, signature: "sha256=deadbeef")

      expect(response).to have_http_status(:unauthorized)
    end

    # Fail closed: with no server-side HMAC secret configured (prod, env var
    # unset), no per-closure secret can be derived and the request MUST be
    # rejected — never fall back to a publicly-known committed default.
    it "fails closed with 401 when no server HMAC secret is configured" do
      # server_secret -> nil is exactly what happens in production when the
      # env var is unset (only dev/test fall back to the dev secret).
      allow(::System::ModuleBuildDispatchService).to receive(:server_secret).and_return(nil)
      expect(::System::PackageBuildWebhookService).not_to receive(:call)

      body = payload.to_json
      deliver(body: body, signature: "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', 'anything', body)}")

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 422 on a WebhookError (validation surfaced, not retried as 500)" do
      allow(::System::PackageBuildWebhookService)
        .to receive(:call).and_raise(::System::PackageBuildWebhookService::WebhookError, "missing modules")

      body = payload.to_json
      deliver(body: body, signature: sign_body(body))

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
