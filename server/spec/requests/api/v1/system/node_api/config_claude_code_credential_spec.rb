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
    # VaultCredentialProvider#get_credential returns a SYMBOL-keyed hash — mock
    # the real shape so this guards BUG-M (a string-keyed read would 503).
    allow(fake_vault).to receive(:get_credential).and_return(api_key: "sk-ant-STUB-VALUE")

    get path, headers: headers

    expect(response).to have_http_status(:ok)
    data = JSON.parse(response.body)["data"]
    expect(data["api_key"]).to eq("sk-ant-STUB-VALUE")
    # The producer DECLARES the kind — the on-node fetch script branches on
    # this instead of inferring from which fields happen to be present.
    expect(data["credential_type"]).to eq("api_key")
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

  # Fallback: a dev-cell with no per-instance credential inherits the account's
  # active Anthropic Ai::Provider key (configured under AI Infrastructure →
  # Providers) instead of requiring a per-instance key for every cell.
  context "when the instance has no per-instance credential but the account has an active Anthropic provider" do
    let!(:anthropic_provider) do
      create(:ai_provider, account: account, provider_type: "anthropic", is_active: true)
    end
    let!(:provider_credential) do
      create(:ai_provider_credential,
             account: account,
             provider: anthropic_provider,
             is_active: true,
             credentials: { "api_key" => "sk-ant-ACCOUNT-PROVIDER" })
    end

    before do
      # The account-provider fallback is opt-in (default OFF) — enable it here.
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get)
        .with("dev_cell_account_provider_credential_fallback").and_return("true")
    end

    it "falls back to the account's Anthropic provider api_key" do
      get path, headers: headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "api_key")).to eq("sk-ant-ACCOUNT-PROVIDER")
    end

    it "prefers the per-instance credential over the account-provider fallback" do
      create(:system_claude_code_credential, node_instance: instance)
      allow(fake_vault).to receive(:get_credential).and_return(api_key: "sk-ant-INSTANCE")

      get path, headers: headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "api_key")).to eq("sk-ant-INSTANCE")
    end

    it "ignores an INACTIVE Anthropic provider (404 when none is active)" do
      anthropic_provider.update!(is_active: false)
      get path, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "does NOT fall back when the fallback SiteSetting is disabled (default)" do
      allow(::SiteSetting).to receive(:get)
        .with("dev_cell_account_provider_credential_fallback").and_return(nil)
      get path, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # --- OAuth (Claude subscription) credential kind -----------------------
  context "when the instance's credential is oauth-kind" do
    let!(:credential) do
      create(:system_claude_code_credential, node_instance: instance, credential_kind: "oauth")
    end
    let(:oauth_blob) do
      {
        "accessToken" => "fake-oauth-access-token-for-spec",
        "refreshToken" => "fake-oauth-refresh-token-for-spec",
        "expiresAt" => 4_102_444_800_000,
        "refreshTokenExpiresAt" => 4_102_444_800_000,
        "scopes" => ["user:inference"],
        "subscriptionType" => "max"
      }
    end

    it "returns the blob wrapped in the ~/.claude/.credentials.json file shape, reading Vault under the oauth type" do
      expect(fake_vault).to receive(:get_credential).with(
        hash_including(credential_type: :claude_code_oauth, credential_id: credential.id)
      ).and_return(oauth: oauth_blob)

      get path, headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      expect(data["credential_type"]).to eq("oauth")
      # The node writes data.oauth_credentials VERBATIM as ~/.claude/.credentials.json.
      expect(data.dig("oauth_credentials", "claudeAiOauth", "refreshToken"))
        .to eq("fake-oauth-refresh-token-for-spec")
      expect(data).not_to have_key("api_key")
    end

    it "returns 503 when Vault has no oauth material for the existing row" do
      allow(fake_vault).to receive(:get_credential).and_return({})
      get path, headers: headers
      expect(response).to have_http_status(:service_unavailable)
    end

    it "accepts the STRING-keyed shape the Vault-less DB fallback returns (ops-hub)" do
      allow(fake_vault).to receive(:get_credential).and_return({ "oauth" => oauth_blob })
      get path, headers: headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "oauth_credentials", "claudeAiOauth", "refreshToken"))
        .to eq("fake-oauth-refresh-token-for-spec")
    end
  end

  it "returns 401 without mTLS auth" do
    get path
    expect(response).to have_http_status(:unauthorized)
  end
end
