# frozen_string_literal: true

require "rails_helper"

# claude-tmux NodeModule — the mTLS-authenticated instance-side read path
# for GET /api/v1/system/node_api/config/claude_code_credential.
RSpec.describe "Api::V1::System::NodeApi::Config#claude_code_credential", type: :request do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node) { create(:system_node, account: account, node_template: node_template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:other_instance) { create(:system_node_instance, :running, node: node) }

  let!(:active_cert) do
    System::NodeCertificate.create!(
      node_instance: instance,
      serial:         SecureRandom.hex(16),
      subject:        "CN=#{instance.id}",
      not_before:     1.hour.ago,
      not_after:      90.days.from_now,
      issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:headers) do
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) }
  end

  let(:path) { "/api/v1/system/node_api/config/claude_code_credential" }

  let(:fake_vault) { instance_double("Security::VaultCredentialProvider") }
  before do
    allow(::Security::VaultCredentialProvider).to receive(:new).and_return(fake_vault)
  end

  it "returns 404 when no credential has been configured for this instance" do
    get path, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "returns the api_key from Vault for the authenticated instance" do
    create(:system_claude_code_credential, node_instance: instance)
    allow(fake_vault).to receive(:get_credential).and_return("api_key" => "sk-ant-STUB-VALUE")

    get path, headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("data", "api_key")).to eq("sk-ant-STUB-VALUE")
  end

  it "never leaks another instance's credential" do
    create(:system_claude_code_credential, node_instance: other_instance)
    # No credential exists for `instance` itself.
    get path, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "returns 503 when Vault has no material for an existing row" do
    create(:system_claude_code_credential, node_instance: instance)
    allow(fake_vault).to receive(:get_credential).and_return({})

    get path, headers: headers
    expect(response).to have_http_status(:service_unavailable)
  end

  it "returns 401 without mTLS auth" do
    get path
    expect(response).to have_http_status(:unauthorized)
  end
end
