# frozen_string_literal: true

require "rails_helper"

# DK1 restoration — CI-direct registry config fetch. Bearer-authenticated
# via the Worker table (same idiom as module_publications), gated on
# system.platforms.publish_disk_image (the ci_worker role's one permission),
# and served from System::DiskImageRegistryConfig.
RSpec.describe "GET /api/v1/system/disk_image_registry_config", type: :request do
  let(:account) { create(:account) }

  let(:ci_token) { "ci-tok-#{SecureRandom.hex(8)}" }
  let!(:ci_worker) do
    ::Worker.create_worker!(
      name:    "test-ci-worker-#{SecureRandom.hex(4)}",
      account: account,
      roles:   [ "ci_worker" ],
      token:   ci_token
    )
  end
  let(:bearer) { { "Authorization" => "Bearer #{ci_token}" } }

  before do
    AdminSetting.where(key: System::DiskImageRegistryConfig::HOST_SETTING_KEY).delete_all
    Security::Secret.where(scope: System::DiskImageRegistryConfig::SECRET_SCOPE).delete_all
  end

  describe "authentication" do
    it "returns 401 without a bearer" do
      get "/api/v1/system/disk_image_registry_config"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 for a bearer that isn't a known Worker token" do
      get "/api/v1/system/disk_image_registry_config",
          headers: { "Authorization" => "Bearer not-a-real-worker-token" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "authorization" do
    it "returns 403 for a worker without system.platforms.publish_disk_image" do
      plain_token = "ci-tok-plain-#{SecureRandom.hex(8)}"
      ::Worker.create_worker!(name: "generic-#{SecureRandom.hex(4)}", account: account, token: plain_token)

      get "/api/v1/system/disk_image_registry_config",
          headers: { "Authorization" => "Bearer #{plain_token}" }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "when unconfigured" do
    it "returns 503 rather than the seed placeholder" do
      get "/api/v1/system/disk_image_registry_config", headers: bearer
      expect(response).to have_http_status(:service_unavailable)
    end
  end

  describe "when configured" do
    before do
      AdminSetting.set(System::DiskImageRegistryConfig::HOST_SETTING_KEY, "git.powernode.org")
      Security::SecretStore.write(account: nil, scope: System::DiskImageRegistryConfig::SECRET_SCOPE,
                                   key: "registry_user", value: "ci-bot")
      Security::SecretStore.write(account: nil, scope: System::DiskImageRegistryConfig::SECRET_SCOPE,
                                   key: "registry_token", value: "s3cr3t-registry-token-value")
    end

    it "returns 200 with host + credentials for a permitted ci_worker" do
      get "/api/v1/system/disk_image_registry_config", headers: bearer

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body).fetch("data")
      expect(data["registry_host"]).to eq("git.powernode.org")
      expect(data["registry_user"]).to eq("ci-bot")
      expect(data["registry_token"]).to eq("s3cr3t-registry-token-value")
    end

    it "emits an audit FleetEvent without the token in its payload" do
      expect {
        get "/api/v1/system/disk_image_registry_config", headers: bearer
      }.to change { System::FleetEvent.where(kind: "system.disk_image_registry_config_read").count }.by(1)

      event = System::FleetEvent.where(kind: "system.disk_image_registry_config_read").last
      expect(event.account_id).to eq(account.id)
      expect(event.payload.to_s).not_to include("s3cr3t-registry-token-value")
    end

    it "never writes the registry token to Rails.logger" do
      logged = []
      %i[debug info warn error].each do |level|
        allow(Rails.logger).to receive(level) { |msg| logged << msg.to_s }
      end

      get "/api/v1/system/disk_image_registry_config", headers: bearer

      expect(response).to have_http_status(:ok)
      expect(logged.join("\n")).not_to include("s3cr3t-registry-token-value")
    end
  end
end
