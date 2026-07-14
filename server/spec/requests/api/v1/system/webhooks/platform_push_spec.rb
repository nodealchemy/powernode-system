# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc10 — the Gitea push webhook consumer that inc11 will
# make the SOLE trigger for module builds. Auth mirrors
# Api::V1::System::Webhooks::GiteaModuleController (HMAC over the raw body,
# X-Gitea-Signature / X-Hub-Signature-256); mode routing is delegated to
# System::ModuleBuildTriggerService (covered in depth by its own spec) —
# these specs mock that service to isolate controller concerns: auth,
# repo/ref/sha extraction, and always-200 webhook-receiver behavior.
RSpec.describe "Api::V1::System::Webhooks::PlatformPush", type: :request do
  let!(:account) { create(:account, name: "Powernode") }

  let(:repo_full_name) { "powernode/powernode-system" }
  let(:push_payload) do
    {
      ref: "refs/heads/develop",
      before: "base0000000000000000000000000000000000",
      after: "headsha123400000000000000000000000000000",
      repository: { full_name: repo_full_name }
    }
  end

  def hmac_for(body)
    secret = ::System::ModuleBuildDispatchService.platform_push_webhook_secret_for(repo_full_name)
    OpenSSL::HMAC.hexdigest("sha256", secret, body)
  end

  def post_push(payload = push_payload, signature: :auto, signature_header: "X-Gitea-Signature")
    body = payload.to_json
    headers = { "Content-Type" => "application/json" }
    headers[signature_header] = signature == :auto ? hmac_for(body) : signature if signature_header
    post "/api/v1/system/webhooks/gitea/platform_push", params: body, headers: headers
  end

  describe "auth" do
    it "returns 200 + no-op message on a validly-signed push (gitea mode, the default)" do
      post_push
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["status"]).to eq("ok")
      expect(json["message"]).to include("mode=gitea").and include("no-op")
    end

    it "accepts X-Hub-Signature-256 with a sha256= prefix" do
      body = push_payload.to_json
      secret = ::System::ModuleBuildDispatchService.platform_push_webhook_secret_for(repo_full_name)
      sig = "sha256=#{OpenSSL::HMAC.hexdigest('sha256', secret, body)}"
      post "/api/v1/system/webhooks/gitea/platform_push",
           params: body, headers: { "Content-Type" => "application/json", "X-Hub-Signature-256" => sig }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to include("mode=gitea")
    end

    it "returns 200 with 'Invalid signature' on a bad signature, never 500" do
      post_push(signature: "deadbeef")
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to eq("Invalid signature")
    end

    it "returns 200 with 'Invalid signature' on a completely unsigned request (no legacy opt-out)" do
      post_push(signature_header: nil)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to eq("Invalid signature")
    end

    it "fails closed (rejects) when no server secret is configured at all" do
      allow(::System::ModuleBuildDispatchService).to receive(:server_secret).and_return(nil)
      post_push(signature: "sha256=#{OpenSSL::HMAC.hexdigest('sha256', 'anything', push_payload.to_json)}")
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to eq("Invalid signature")
    end

    it "ignores a push to an unrecognized repository" do
      payload = push_payload.deep_merge(repository: { full_name: "someone/unrelated" })
      body = payload.to_json
      post "/api/v1/system/webhooks/gitea/platform_push",
           params: body, headers: { "Content-Type" => "application/json", "X-Gitea-Signature" => hmac_for(body) }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to eq("repository not recognized")
    end
  end

  describe "ref filtering" do
    it "ignores a push to a non-target branch" do
      post_push(push_payload.merge(ref: "refs/heads/feature/whatever"))
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to include("ignored ref")
    end

    it "ignores a branch-delete push (after is all-zero sha)" do
      post_push(push_payload.merge(after: "0" * 40))
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to include("ignored ref")
    end

    it "ignores an initial branch-creation push (before is all-zero sha — no diff base)" do
      post_push(push_payload.merge(before: "0" * 40))
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to include("ignored ref")
    end

    it "honors an operator-configured trigger_ref override" do
      SiteSetting.set("system.module_builds.trigger_ref", "refs/heads/main")
      post_push(push_payload.merge(ref: "refs/heads/main"))
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to include("mode=gitea")
    end
  end

  describe "mode routing delegation" do
    it "delegates base_sha/head_sha to ModuleBuildTriggerService and reflects a dual-mode dispatch in the response" do
      trigger_result = System::ModuleBuildTriggerService::Result.new(
        ok?: true, mode: "dual", dispatched: true, shadow: true, batch: double("batch", id: "batch-123") # rubocop:disable RSpec/VerifiedDoubles
      )
      expect(::System::ModuleBuildTriggerService).to receive(:trigger!)
        .with(base_sha: push_payload[:before], head_sha: push_payload[:after])
        .and_return(trigger_result)

      post_push
      expect(response).to have_http_status(:ok)
      msg = JSON.parse(response.body)["message"]
      expect(msg).to include("mode=dual").and include("shadow=true").and include("batch-123")
    end

    it "returns 200 with the trigger's error message when the service reports a failure (never 500)" do
      trigger_result = System::ModuleBuildTriggerService::Result.new(
        ok?: false, mode: "dual", error: "no active Gitea credential resolvable"
      )
      allow(::System::ModuleBuildTriggerService).to receive(:trigger!).and_return(trigger_result)

      post_push
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to include("trigger failed").and include("no active Gitea credential resolvable")
    end

    it "returns 200 even when ModuleBuildTriggerService raises unexpectedly" do
      allow(::System::ModuleBuildTriggerService).to receive(:trigger!).and_raise(StandardError, "boom")

      post_push
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to eq("Processing error")
    end
  end
end
