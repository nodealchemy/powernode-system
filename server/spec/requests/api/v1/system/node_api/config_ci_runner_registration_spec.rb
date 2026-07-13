# frozen_string_literal: true

require "rails_helper"

# gitea-act-runner NodeModule — the mTLS-authenticated instance-side read
# path for GET /api/v1/system/node_api/config/ci_runner_registration.
#
# SECURITY: these specs assert only the PRESENCE/SHAPE of the registration
# token — never a real Gitea network call (Devops::Git::ApiClient is
# stubbed, same pattern config_dev_cell_bootstrap_spec.rb uses).
RSpec.describe "Api::V1::System::NodeApi::Config#ci_runner_registration", type: :request do
  let(:account) { create(:account) }

  let(:gitea_provider) { create(:git_provider, :gitea, account: account) }
  let!(:gitea_credential) do
    create(:git_provider_credential, :gitea, account: account, provider: gitea_provider)
  end

  let(:node_template) { create(:system_node_template, account: account) }
  let(:node) { create(:system_node, account: account, node_template: node_template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  # Mark the node a genuine gitea-act-runner: assign the module to it.
  let(:ci_runner_module) { create(:system_node_module, account: account, name: "gitea-act-runner") }
  let!(:ci_runner_assignment) do
    create(:system_node_module_assignment, node: node, node_module: ci_runner_module)
  end

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

  let(:path) { "/api/v1/system/node_api/config/ci_runner_registration" }

  let(:fake_gitea_client) { instance_double("Devops::Git::GiteaApiClient") }

  before do
    allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake_gitea_client)
    allow(fake_gitea_client).to receive(:supports_runners?).and_return(true)
    allow(fake_gitea_client).to receive(:runner_registration_token)
      .and_return(token: "GTA-STUB-REG-TOKEN", expires_at: nil)
  end

  def json
    JSON.parse(response.body)
  end

  describe "happy path (genuine gitea-act-runner)" do
    it "returns the mint bundle with the correct shape" do
      get path, headers: headers

      expect(response).to have_http_status(:ok)

      data = json["data"]
      expect(data.keys).to contain_exactly(
        "gitea_instance_url", "registration_token", "runner_name", "labels", "ephemeral"
      )
      expect(data["gitea_instance_url"]).to eq(gitea_provider.effective_web_base_url)
      expect(data["registration_token"]).to eq("GTA-STUB-REG-TOKEN")
      # P0-1 collision fix (campaign 019f5885 inc3): runner_name is now the
      # random UUIDv7 TAIL, not id.first(8) (which collides for any two ids
      # minted in the same ~65.5s window — see CiRunnerRegistrationResolver).
      expect(data["runner_name"]).to eq(::System::CiRunnerRegistrationResolver.runner_name(instance))
      expect(data["runner_name"]).not_to eq("fleet-#{instance.id.first(8)}")
      expect(data["labels"]).to eq([ "fleet-amd64:docker://ghcr.io/catthehacker/ubuntu:act-24.04" ])
      expect(data["ephemeral"]).to eq(false)
    end

    it "requests an ORG-scope token for the default owner (powernode) by default" do
      get path, headers: headers

      expect(fake_gitea_client).to have_received(:runner_registration_token)
        .with("powernode", nil, scope: :org)
    end

    it "never returns the token anywhere but the response body — the emitted fleet event carries ids only" do
      allow(::System::Fleet::EventBroadcaster).to receive(:emit!)

      get path, headers: headers

      expect(::System::Fleet::EventBroadcaster).to have_received(:emit!) do |**kwargs|
        expect(kwargs[:kind]).to eq("system.ci_runner_registration_issued")
        expect(kwargs[:payload]).to eq({ "instance_id" => instance.id })
        expect(kwargs[:payload].to_s).not_to include("GTA-STUB-REG-TOKEN")
      end
    end
  end

  describe "SiteSetting overrides" do
    it "honors ci_runner_scope / ci_runner_owner / ci_runner_repo for a repo-scope mint" do
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("ci_runner_scope").and_return("repo")
      allow(::SiteSetting).to receive(:get).with("ci_runner_owner").and_return("acme")
      allow(::SiteSetting).to receive(:get).with("ci_runner_repo").and_return("widgets")

      get path, headers: headers

      expect(response).to have_http_status(:ok)
      expect(fake_gitea_client).to have_received(:runner_registration_token)
        .with("acme", "widgets", scope: :repo)
    end

    it "honors ci_runner_label" do
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("ci_runner_label").and_return("fleet-gpu")

      get path, headers: headers

      expect(json.dig("data", "labels")).to eq([ "fleet-gpu" ])
    end

    it "honors ci_runner_ephemeral" do
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("ci_runner_ephemeral").and_return("true")

      get path, headers: headers

      expect(json.dig("data", "ephemeral")).to eq(true)
    end

    it "prefers an explicit ci_runner_git_credential_id over the single-active-credential fallback" do
      other_credential = create(:git_provider_credential, :gitea, account: account, provider: gitea_provider)
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("ci_runner_git_credential_id").and_return(other_credential.id)

      get path, headers: headers

      expect(response).to have_http_status(:ok)
    end
  end

  describe "authorization gate" do
    let(:plain_node) { create(:system_node, account: account, node_template: node_template) }
    let(:plain_instance) { create(:system_node_instance, :running, node: plain_node) }
    let!(:plain_cert) do
      System::NodeCertificate.create!(
        node_instance: plain_instance, serial: SecureRandom.hex(16),
        subject: "CN=#{plain_instance.id}", not_before: 1.hour.ago,
        not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
      )
    end
    let(:plain_headers) do
      { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{plain_instance.id}")) }
    end

    it "403s an mTLS instance whose node is NOT provisioned as a gitea-act-runner — no token minted" do
      get path, headers: plain_headers

      expect(response).to have_http_status(:forbidden)
      expect(fake_gitea_client).not_to have_received(:runner_registration_token)
    end
  end

  describe "credential resolution failures" do
    it "404s when the account has no active Gitea credential" do
      gitea_credential.update!(is_active: false)

      get path, headers: headers

      expect(response).to have_http_status(:not_found)
      expect(fake_gitea_client).not_to have_received(:runner_registration_token)
    end

    it "404s (does not guess) when the account has more than one active Gitea credential and no override is configured" do
      create(:git_provider_credential, :gitea, account: account, provider: gitea_provider)

      get path, headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "provider-side failure" do
    it "503s when the provider returns no token" do
      allow(fake_gitea_client).to receive(:supports_runners?).and_return(false)

      get path, headers: headers

      expect(response).to have_http_status(:service_unavailable)
    end
  end

  it "returns 401 without mTLS auth" do
    get path
    expect(response).to have_http_status(:unauthorized)
  end
end
