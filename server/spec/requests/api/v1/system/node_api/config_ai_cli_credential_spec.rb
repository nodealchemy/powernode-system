# frozen_string_literal: true

require "rails_helper"

# grok-cli NodeModule — the mTLS-authenticated instance-side read path for
# GET /api/v1/system/node_api/config/ai_cli_credential?provider_type=<t>,
# the provider-general form of #claude_code_credential.
#
# The sibling spec config_claude_code_credential_spec.rb covers the anthropic
# path through the SAME resolver and is deliberately left alone: it is the
# regression guard that adding a provider did not change what a deployed
# claude-tmux node sees. This file covers what is genuinely new — the
# provider allow-list, per-provider isolation, and the per-provider spend
# flag.
RSpec.describe "Api::V1::System::NodeApi::Config#ai_cli_credential", type: :request do
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

  let(:base_path) { "/api/v1/system/node_api/config/ai_cli_credential" }
  let(:path) { "#{base_path}?provider_type=grok" }

  let(:fake_vault) { instance_double("Security::VaultCredentialProvider") }
  before do
    allow(::Security::VaultCredentialProvider).to receive(:new).and_return(fake_vault)
  end

  describe "the provider_type allow-list" do
    # provider_type reaches a Vault path segment and an Ai::Provider lookup.
    # An enrolled instance must not be able to name a provider no module of
    # its own ever needed and see what comes back.
    it "rejects a provider outside PROVIDER_TYPES" do
      get "#{base_path}?provider_type=openai", headers: headers
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects an absent provider_type rather than defaulting to one" do
      get base_path, headers: headers
      expect(response).to have_http_status(:bad_request)
    end
  end

  it "returns 404 when no grok credential has been configured for this instance" do
    get path, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "returns the api_key from Vault for the authenticated instance" do
    create(:system_claude_code_credential, node_instance: instance, provider_type: "grok")
    # VaultCredentialProvider#get_credential returns a SYMBOL-keyed hash.
    allow(fake_vault).to receive(:get_credential).and_return(api_key: "xai-STUB-VALUE")

    get path, headers: headers

    expect(response).to have_http_status(:ok)
    data = JSON.parse(response.body)["data"]
    expect(data["api_key"]).to eq("xai-STUB-VALUE")
    expect(data["credential_type"]).to eq("api_key")
  end

  it "reads the row under the provider's OWN vault path segment" do
    credential = create(:system_claude_code_credential, node_instance: instance, provider_type: "grok")
    expect(fake_vault).to receive(:get_credential)
      .with(hash_including(credential_type: :grok_api_key, credential_id: credential.id))
      .and_return(api_key: "xai-STUB-VALUE")

    get path, headers: headers
    expect(response).to have_http_status(:ok)
  end

  # The whole point of scoping the row to a provider: one instance carrying
  # both modules must not have either credential answer for the other.
  it "does not serve the anthropic credential when asked for grok" do
    create(:system_claude_code_credential, node_instance: instance, provider_type: "anthropic")

    get path, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "serves each provider its own credential on the same instance" do
    create(:system_claude_code_credential, node_instance: instance, provider_type: "anthropic")
    create(:system_claude_code_credential, node_instance: instance, provider_type: "grok")
    allow(fake_vault).to receive(:get_credential) do |credential_type:, **|
      credential_type == :grok_api_key ? { api_key: "xai-GROK" } : { api_key: "sk-ant-CLAUDE" }
    end

    get path, headers: headers
    expect(JSON.parse(response.body).dig("data", "api_key")).to eq("xai-GROK")

    get "/api/v1/system/node_api/config/claude_code_credential", headers: headers
    expect(JSON.parse(response.body).dig("data", "api_key")).to eq("sk-ant-CLAUDE")
  end

  it "never leaks another instance's credential" do
    create(:system_claude_code_credential, node_instance: other_instance, provider_type: "grok")
    # No credential exists for `instance` itself.
    get path, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "returns 503 when Vault has no material for an existing row" do
    create(:system_claude_code_credential, node_instance: instance, provider_type: "grok")
    allow(fake_vault).to receive(:get_credential).and_return({})

    get path, headers: headers
    expect(response).to have_http_status(:service_unavailable)
  end

  # The account-provider fallback is a SPEND AUTHORIZATION, and it is
  # per-provider: enabling it for Anthropic must not also let every enrolled
  # instance start drawing on the account's xAI budget.
  context "account-provider fallback" do
    let!(:grok_provider) do
      create(:ai_provider, account: account, provider_type: "grok", is_active: true)
    end
    let!(:grok_credential) do
      create(:ai_provider_credential,
             account: account,
             provider: grok_provider,
             is_active: true,
             credentials: { "api_key" => "xai-ACCOUNT-PROVIDER" })
    end

    before do
      allow(::SiteSetting).to receive(:get).and_call_original
    end

    it "falls back to the account's grok provider api_key when ITS flag is on" do
      allow(::SiteSetting).to receive(:get)
        .with("grok_cli_account_provider_credential_fallback").and_return("true")

      get path, headers: headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "api_key")).to eq("xai-ACCOUNT-PROVIDER")
    end

    it "does NOT fall back by default (no flag set)" do
      get path, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "does NOT fall back on the ANTHROPIC flag — each provider authorizes its own spend" do
      allow(::SiteSetting).to receive(:get)
        .with("dev_cell_account_provider_credential_fallback").and_return("true")
      allow(::SiteSetting).to receive(:get)
        .with("grok_cli_account_provider_credential_fallback").and_return(nil)

      get path, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "ignores an INACTIVE grok provider" do
      allow(::SiteSetting).to receive(:get)
        .with("grok_cli_account_provider_credential_fallback").and_return("true")
      grok_provider.update!(is_active: false)

      get path, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "prefers the per-instance credential over the account-provider fallback" do
      allow(::SiteSetting).to receive(:get)
        .with("grok_cli_account_provider_credential_fallback").and_return("true")
      create(:system_claude_code_credential, node_instance: instance, provider_type: "grok")
      allow(fake_vault).to receive(:get_credential).and_return(api_key: "xai-INSTANCE")

      get path, headers: headers
      expect(JSON.parse(response.body).dig("data", "api_key")).to eq("xai-INSTANCE")
    end
  end
end
