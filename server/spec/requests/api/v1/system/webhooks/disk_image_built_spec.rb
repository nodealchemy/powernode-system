# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Disk image built webhook", type: :request do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, account: account, name: "ubuntu-24.04-rpi4") }
  let!(:webhook_pair) { ::System::DiskImageWebhook.create_with_secret!(account: account, label: "test-pipeline") }
  let(:webhook) { webhook_pair[0] }
  let(:secret) { webhook_pair[1] }

  let(:payload) do
    {
      platform_name: platform.name,
      sha256:        "a" * 64,
      size_bytes:    10_485_760,
      git_sha:       "abc123",
      oci_ref:       "registry.example.com/powernode/disk-images/test:abc123",
      arch:          "arm64",
      firmware_ref:  "1.20240306"
    }
  end

  def hmac_sig(body, sec)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', sec, body)}"
  end

  before do
    # Force inline mode so the processor runs in-test (and we can stub it).
    ENV["POWERNODE_WEBHOOK_INGEST_MODE"] = "inline"
    allow(::System::DiskImagePublicationProcessor).to receive(:process!) do |publication:|
      ::System::DiskImagePublicationProcessor::Result.new(ok?: true, publication: publication)
    end
  end

  after do
    ENV.delete("POWERNODE_WEBHOOK_INGEST_MODE")
  end

  describe "POST /api/v1/system/webhooks/disk_image/built/:webhook_id" do
    it "accepts a correctly signed payload + creates a publication" do
      body = payload.to_json
      expect {
        post "/api/v1/system/webhooks/disk_image/built/#{webhook.id}",
             params: body,
             headers: { "Content-Type" => "application/json", "X-Powernode-Signature" => hmac_sig(body, secret) }
      }.to change(::System::DiskImagePublication, :count).by(1)

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["success"]).to be true
      expect(data["status"]).to eq("queued")
      expect(data["publication_id"]).to be_present

      pub = ::System::DiskImagePublication.find(data["publication_id"])
      expect(pub.account_id).to eq(account.id)
      expect(pub.git_sha).to eq("abc123")
      expect(pub.webhook_id).to eq(webhook.id)
    end

    it "returns 200 with 'unknown_webhook' for a bad webhook_id (never 500)" do
      post "/api/v1/system/webhooks/disk_image/built/00000000-0000-0000-0000-000000000000",
           params: payload.to_json,
           headers: { "Content-Type" => "application/json", "X-Powernode-Signature" => "sha256=anything" }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["status"]).to eq("error")
      expect(JSON.parse(response.body)["reason"]).to eq("unknown_webhook")
    end

    it "returns 200 with 'bad_signature' for a wrong HMAC (never 500)" do
      body = payload.to_json
      post "/api/v1/system/webhooks/disk_image/built/#{webhook.id}",
           params: body,
           headers: { "Content-Type" => "application/json", "X-Powernode-Signature" => "sha256=deadbeef" }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["status"]).to eq("error")
      expect(JSON.parse(response.body)["reason"]).to eq("bad_signature")
    end

    it "returns 'unknown_platform' for a platform_name that doesn't belong to this account" do
      other_account = create(:account)
      other_platform = create(:system_node_platform, account: other_account, name: "other-platform")

      body = payload.merge(platform_name: other_platform.name).to_json
      post "/api/v1/system/webhooks/disk_image/built/#{webhook.id}",
           params: body,
           headers: { "Content-Type" => "application/json", "X-Powernode-Signature" => hmac_sig(body, secret) }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["reason"]).to eq("unknown_platform")
    end

    it "is idempotent on re-receive of the same git_sha (returns idempotent_hit when already published)" do
      pub = create(:system_disk_image_publication, :published, account: account, node_platform: platform, git_sha: "duplicate")
      body = payload.merge(git_sha: "duplicate").to_json

      expect {
        post "/api/v1/system/webhooks/disk_image/built/#{webhook.id}",
             params: body,
             headers: { "Content-Type" => "application/json", "X-Powernode-Signature" => hmac_sig(body, secret) }
      }.not_to change(::System::DiskImagePublication, :count)

      expect(JSON.parse(response.body)["status"]).to eq("idempotent_hit")
      expect(JSON.parse(response.body)["publication_id"]).to eq(pub.id)
    end

    it "bumps the webhook's received_count + last_received_at" do
      body = payload.to_json
      expect {
        post "/api/v1/system/webhooks/disk_image/built/#{webhook.id}",
             params: body,
             headers: { "Content-Type" => "application/json", "X-Powernode-Signature" => hmac_sig(body, secret) }
        webhook.reload
      }.to change { webhook.reload.received_count }.by(1)

      expect(webhook.reload.last_received_at).to be_present
    end

    it "rejects a disabled webhook with 'unknown_webhook' (active scope filters)" do
      webhook.update!(status: "disabled")
      body = payload.to_json
      post "/api/v1/system/webhooks/disk_image/built/#{webhook.id}",
           params: body,
           headers: { "Content-Type" => "application/json", "X-Powernode-Signature" => hmac_sig(body, secret) }
      expect(JSON.parse(response.body)["reason"]).to eq("unknown_webhook")
    end

    it "returns 200 with an error reason for unparseable JSON (never 500)" do
      # Use text/plain so Rails' built-in JSON parser doesn't reject the
      # body before the controller sees it; controller's parse_payload
      # then handles JSON parse failure gracefully.
      body = "this is not json"
      post "/api/v1/system/webhooks/disk_image/built/#{webhook.id}",
           params: body,
           headers: { "Content-Type" => "text/plain", "X-Powernode-Signature" => hmac_sig(body, secret) }
      expect(response).to have_http_status(:ok)
      reason = JSON.parse(response.body)["reason"]
      # Either the controller's parse_payload returns nil → "invalid_payload",
      # or the rescue catches a downstream raise → "processing_error".
      # Both prove never-500 discipline.
      expect(%w[invalid_payload processing_error]).to include(reason)
    end
  end
end
