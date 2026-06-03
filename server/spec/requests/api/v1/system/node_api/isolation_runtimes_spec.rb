# frozen_string_literal: true

require "rails_helper"

# AI/MCP workload substrate L0 — node-facing isolation runtimes config. The
# agent pulls the runtimes it should provision (from its isolation tier).
RSpec.describe "Api::V1::System::NodeApi::Isolation#runtimes", type: :request do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:instance) do
    create(:system_node_instance, :running, node: node,
                                            config: { "isolation" => { "tier" => "gvisor", "docker_runtime" => "runsc" } })
  end

  let!(:active_cert) do
    System::NodeCertificate.create!(
      node_instance: instance, serial: SecureRandom.hex(16), subject: "CN=#{instance.id}",
      not_before: 1.hour.ago, not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:headers) { { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) } }

  describe "GET /api/v1/system/node_api/isolation/runtimes" do
    it "returns the runtimes the node should provision (from its isolation tier)" do
      get "/api/v1/system/node_api/isolation/runtimes", headers: headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "runtimes")).to eq(%w[gvisor])
    end

    it "returns [] for a native (or unset) tier" do
      instance.update!(config: { "isolation" => { "tier" => "native" } })
      get "/api/v1/system/node_api/isolation/runtimes", headers: headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "runtimes")).to eq([])
    end

    it "401 without an instance cert" do
      get "/api/v1/system/node_api/isolation/runtimes"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
