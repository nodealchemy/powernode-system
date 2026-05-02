# frozen_string_literal: true

require "rails_helper"
require "openssl"

RSpec.describe "Api::V1::System::NodeApi::Enrollment", type: :request do
  before { System::InternalCaService.reset! }

  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  let(:keypair) { OpenSSL::PKey.generate_key("ED25519") }
  let(:csr_pem) do
    csr = OpenSSL::X509::Request.new
    csr.version = 0
    csr.subject = OpenSSL::X509::Name.parse("/CN=#{instance.id}")
    csr.public_key = keypair
    csr.sign(keypair, nil)
    csr.to_pem
  end

  let(:token_pair) do
    System::BootstrapToken.issue!(
      node: node, intended_subject: instance.id, node_instance: instance
    )
  end
  let(:token_plaintext) { token_pair[1] }

  describe "POST /api/v1/system/node_api/enroll" do
    it "returns cert + chain + instance_id with body params" do
      post "/api/v1/system/node_api/enroll",
           params: { bootstrap_token: token_plaintext, csr_pem: csr_pem, agent_version: "0.1.0" }

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body).fetch("data")
      expect(data["cert_pem"]).to include("BEGIN CERTIFICATE")
      expect(data["ca_chain_pem"]).to include("BEGIN CERTIFICATE")
      expect(data["instance_id"]).to eq(instance.id)
      expect(data["mtls_subject"]).to eq(instance.id)
    end

    it "issues an instance JWT alongside the cert (legacy auth path)" do
      post "/api/v1/system/node_api/enroll",
           params: { bootstrap_token: token_plaintext, csr_pem: csr_pem }

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body).fetch("data")
      expect(data["instance_token"]).to be_present
      payload = ::Security::JwtService.decode(data["instance_token"])
      expect(payload[:type] || payload["type"]).to eq("instance")
      expect(payload[:sub] || payload["sub"]).to eq(instance.id)
    end

    it "accepts the token via X-Bootstrap-Token header" do
      post "/api/v1/system/node_api/enroll",
           params: { csr_pem: csr_pem },
           headers: { "X-Bootstrap-Token" => token_plaintext }

      expect(response).to have_http_status(:ok)
    end

    it "returns 401 when no bootstrap token is presented" do
      post "/api/v1/system/node_api/enroll", params: { csr_pem: csr_pem }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 422 with an invalid token" do
      post "/api/v1/system/node_api/enroll",
           params: { bootstrap_token: "definitely-not-real", csr_pem: csr_pem }
      expect(response).to have_http_status(422)
    end

    it "returns 422 with a missing csr_pem" do
      post "/api/v1/system/node_api/enroll",
           params: { bootstrap_token: token_plaintext }
      expect(response).to have_http_status(:bad_request).or have_http_status(422)
    end
  end
end
