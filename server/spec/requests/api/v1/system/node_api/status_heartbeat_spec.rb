# frozen_string_literal: true

require "rails_helper"

# Exercises the rewritten heartbeat endpoint (M0.M / M2 — agent post-enroll
# heartbeat). The endpoint persists into NodeInstance's dedicated runtime
# columns via record_heartbeat! and AASM-transitions the instance from a
# pre-running state into running on first heartbeat.
RSpec.describe "Api::V1::System::NodeApi::Status#heartbeat", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "pending") }
  let(:auth_token) do
    ::Security::JwtService.encode({
      sub:     instance.id,
      type:    "instance",
      version: ::Security::JwtService::CURRENT_TOKEN_VERSION
    })
  end
  let(:headers) { { "X-Instance-Token" => auth_token } }

  let(:body) do
    {
      boot_id:        "boot-test-1",
      agent_version:  "1.0.0-test",
      architecture:   "amd64",
      uptime_seconds: 42,
      module_digests: { "system-base" => "sha256:aaaa" },
      mount_state:    "mounted"
    }
  end

  describe "POST /api/v1/system/node_api/status/heartbeat" do
    it "persists telemetry into the dedicated NodeInstance columns" do
      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig("data", "acknowledged")).to be(true)
      expect(json.dig("data", "next_poll_seconds")).to eq(30)

      instance.reload
      expect(instance.last_heartbeat_at).to be_within(5.seconds).of(Time.current)
      expect(instance.agent_version).to eq("1.0.0-test")
      expect(instance.boot_id).to eq("boot-test-1")
      expect(instance.running_module_digests).to eq("system-base" => "sha256:aaaa")
    end

    it "transitions pending → running on first heartbeat" do
      expect(instance.status).to eq("pending")

      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(instance.reload.status).to eq("running")
    end

    it "leaves status unchanged when already running" do
      instance.update!(status: "running")

      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(instance.reload.status).to eq("running")
    end

    it "tolerates a missing module_digests body field" do
      body.delete(:module_digests)
      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(instance.reload.running_module_digests).to eq({})
    end

    it "rejects requests with no auth token" do
      post "/api/v1/system/node_api/status/heartbeat", params: body, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
