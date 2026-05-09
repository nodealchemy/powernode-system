# frozen_string_literal: true

require "rails_helper"

# Exercises the cert rotation endpoint added in Phase 1 of the agent
# stub implementation plan. Confirms:
#   - mTLS / JWT auth gate (no bootstrap token accepted)
#   - Re-issues with same CN as existing instance
#   - Persists new NodeCertificate (old row preserved)
#   - Returns fresh instance_token for legacy auth path
RSpec.describe "Api::V1::System::NodeApi::EnrollmentRefresh#refresh", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance) do
    create(:system_node_instance,
           node: node,
           status: "running",
           mtls_subject: "instance-cn-1234")
  end
  let(:auth_token) do
    ::Security::JwtService.encode({
      sub:     instance.id,
      type:    "instance",
      version: ::Security::JwtService::CURRENT_TOKEN_VERSION
    })
  end
  let(:headers) { { "X-Instance-Token" => auth_token } }

  # Generate a real Ed25519 CSR for the test — InternalCaService validates
  # the CSR format strictly, so a stub string would be rejected.
  let(:csr_pem) do
    require "openssl"
    key = OpenSSL::PKey.generate_key("ED25519")
    csr = OpenSSL::X509::Request.new
    csr.subject = OpenSSL::X509::Name.new([["CN", "instance-cn-1234"]])
    csr.public_key = key
    csr.sign(key, nil) # Ed25519 doesn't take a digest
    csr.to_pem
  end

  let(:body) { { csr_pem: csr_pem, agent_version: "0.2.0-test" } }

  describe "POST /api/v1/system/node_api/enroll/refresh" do
    it "rejects unauthenticated requests" do
      post "/api/v1/system/node_api/enroll/refresh", params: body, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects bootstrap-token-only auth (refresh requires existing instance cert/JWT)" do
      post "/api/v1/system/node_api/enroll/refresh",
           params: body.merge(bootstrap_token: "fake"),
           as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "issues a fresh cert with the same CN as the existing instance" do
      expect {
        post "/api/v1/system/node_api/enroll/refresh",
             params: body, headers: headers, as: :json
      }.to change { ::System::NodeCertificate.where(node_instance_id: instance.id).count }.by(1)

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig("data", "cert_pem")).to be_present
      expect(json.dig("data", "ca_chain_pem")).to be_present
      expect(json.dig("data", "mtls_subject")).to eq("instance-cn-1234")
      expect(json.dig("data", "instance_id")).to eq(instance.id)
      expect(json.dig("data", "instance_token")).to be_present
      expect(json.dig("data", "not_after")).to be_present
    end

    it "preserves rotation history across multiple refreshes" do
      # First refresh.
      post "/api/v1/system/node_api/enroll/refresh", params: body, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      first_cert_id = JSON.parse(response.body).dig("data", "certificate_id")

      # Second refresh — old row preserved (different cert_id), audit trail intact.
      second_csr = OpenSSL::PKey.generate_key("ED25519").then do |k|
        c = OpenSSL::X509::Request.new
        c.subject = OpenSSL::X509::Name.new([["CN", "instance-cn-1234"]])
        c.public_key = k
        c.sign(k, nil)
        c.to_pem
      end
      post "/api/v1/system/node_api/enroll/refresh",
           params: { csr_pem: second_csr }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      second_cert_id = JSON.parse(response.body).dig("data", "certificate_id")

      expect(first_cert_id).not_to eq(second_cert_id)
      expect(::System::NodeCertificate.where(node_instance_id: instance.id).count).to be >= 2
    end

    it "updates agent_version when supplied" do
      post "/api/v1/system/node_api/enroll/refresh",
           params: body.merge(agent_version: "0.3.0"),
           headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(instance.reload.agent_version).to eq("0.3.0")
    end

    it "returns 422 with empty CSR" do
      post "/api/v1/system/node_api/enroll/refresh",
           params: { csr_pem: "" },
           headers: headers, as: :json
      expect(response.status).to be_in([400, 422])
    end

    it "returns 422 with malformed CSR" do
      post "/api/v1/system/node_api/enroll/refresh",
           params: { csr_pem: "-----BEGIN CERTIFICATE REQUEST-----\nGARBAGE\n-----END CERTIFICATE REQUEST-----\n" },
           headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
