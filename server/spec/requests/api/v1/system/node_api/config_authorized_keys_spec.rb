# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M0.H — exercises the existing /node_api/config/authorized_keys
# endpoint with the new System::Node#authorized_keys aggregation.
RSpec.describe "Api::V1::System::NodeApi::Config#authorized_keys", type: :request do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node) { create(:system_node, account: account, node_template: node_template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:auth_token) do
    ::Security::JwtService.encode({
      sub: instance.id,
      type: "instance",
      version: ::Security::JwtService::CURRENT_TOKEN_VERSION
    })
  end
  let(:headers) { { "X-Instance-Token" => auth_token } }

  describe "GET /api/v1/system/node_api/config/authorized_keys" do
    it "returns the aggregated authorized_keys text and count" do
      operator_key = "ssh-ed25519 AAAAfixture operator@host"
      node.update!(config: { "authorized_keys" => [ operator_key ] })

      get "/api/v1/system/node_api/config/authorized_keys", headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig("data", "authorized_keys")).to include(operator_key)
      # The PEM-PKIX node identity public key MUST NOT leak into operator authorized_keys.
      expect(json.dig("data", "authorized_keys")).not_to include("PUBLIC KEY")
      expect(json.dig("data", "keys_count")).to eq(node.authorized_keys.length)
    end

    it "includes operator-supplied keys when set in node config" do
      operator_key = "ssh-ed25519 AAAAfake operator@host"
      node.update!(config: { "authorized_keys" => [ operator_key ] })

      get "/api/v1/system/node_api/config/authorized_keys", headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "authorized_keys")).to include(operator_key)
    end

    it "defaults target_user to 'root' when no admin_user is configured" do
      get "/api/v1/system/node_api/config/authorized_keys", headers: headers
      expect(JSON.parse(response.body).dig("data", "target_user")).to eq("root")
    end

    it "honors instance-level admin_user override" do
      instance.update!(config: (instance.config || {}).merge("admin_user" => "ubuntu"))

      get "/api/v1/system/node_api/config/authorized_keys", headers: headers
      expect(JSON.parse(response.body).dig("data", "target_user")).to eq("ubuntu")
    end

    it "falls back to node-level admin_user when instance has none" do
      node.update!(config: (node.config || {}).merge("admin_user" => "deploy"))

      get "/api/v1/system/node_api/config/authorized_keys", headers: headers
      expect(JSON.parse(response.body).dig("data", "target_user")).to eq("deploy")
    end

    it "returns 401 without auth" do
      get "/api/v1/system/node_api/config/authorized_keys"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 with an invalid token" do
      get "/api/v1/system/node_api/config/authorized_keys",
          headers: { "X-Instance-Token" => "not.a.real.jwt" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/system/node_api/config/host_keys" do
    it "returns the PUBLIC host key (not the private key)" do
      get "/api/v1/system/node_api/config/host_keys", headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      default = json.dig("data", "host_keys", "default")
      expect(default).to be_present
      expect(default).to include("PUBLIC KEY")
      expect(default).not_to include("PRIVATE KEY")
    end
  end
end
