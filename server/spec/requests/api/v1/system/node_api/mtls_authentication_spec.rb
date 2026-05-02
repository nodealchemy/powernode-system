# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M0.P — node_api/base_controller mTLS authentication path.
# Exercises the auth ordering: mTLS preferred, JWT fallback, both missing → 401.
RSpec.describe "Api::V1::System::NodeApi mTLS authentication", type: :request do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  # Issue an active cert so the mTLS path can verify
  let!(:cert) do
    System::NodeCertificate.create!(
      node_instance: instance,
      serial: SecureRandom.hex(16),
      subject: "CN=#{instance.id}",
      not_before: 1.hour.ago,
      not_after:  90.days.from_now,
      issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:probe_path) { "/api/v1/system/node_api/config/authorized_keys" }

  describe "mTLS path" do
    it "authenticates when X-Client-S-DN-CN header matches a NodeInstance.id with an active cert" do
      get probe_path, headers: { "X-Client-S-DN-CN" => instance.id }
      expect(response).to have_http_status(:ok)
    end

    it "returns 401 when the CN matches no instance" do
      get probe_path, headers: { "X-Client-S-DN-CN" => SecureRandom.uuid }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to include("Instance not found for mTLS")
    end

    it "returns 401 when the instance has no active certificate" do
      cert.revoke!(reason: "rotated")
      get probe_path, headers: { "X-Client-S-DN-CN" => instance.id }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to include("No active certificate")
    end

    it "looks up by mtls_subject when CN is not a NodeInstance.id" do
      instance.update!(mtls_subject: "node-instance-#{instance.id}")
      get probe_path, headers: { "X-Client-S-DN-CN" => "node-instance-#{instance.id}" }
      expect(response).to have_http_status(:ok)
    end
  end

  describe "JWT fallback (legacy, during transition)" do
    let(:auth_token) do
      ::Security::JwtService.encode({
        sub: instance.id, type: "instance",
        version: ::Security::JwtService::CURRENT_TOKEN_VERSION
      })
    end

    it "still works when only an Instance-Token is presented" do
      get probe_path, headers: { "X-Instance-Token" => auth_token }
      expect(response).to have_http_status(:ok)
    end

    it "is preferred over JWT when both are present (mTLS wins)" do
      # Set mTLS to a bad CN — request should fail because mTLS path runs first
      # and short-circuits.
      get probe_path, headers: {
        "X-Client-S-DN-CN" => SecureRandom.uuid,
        "X-Instance-Token" => auth_token
      }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "no auth presented" do
    it "returns 401 with both methods absent" do
      get probe_path
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to include("Instance token or mTLS client certificate required")
    end
  end
end
