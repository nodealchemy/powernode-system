# frozen_string_literal: true

require "rails_helper"

# module-forge NodeModule — the mTLS-authenticated instance-side read path
# for GET /api/v1/system/node_api/config/ci_build_context (campaign 019f5885
# inc7). This is the lease-gated tightening #ci_runner_registration's inc5
# hook-point comment flagged: module presence ALONE is not enough here —
# an ACTIVE CiRunnerLease with purpose "module_build" for THIS instance is
# also required.
RSpec.describe "Api::V1::System::NodeApi::Config#ci_build_context", type: :request do
  let(:account) { create(:account) }

  let(:gitea_provider) { create(:git_provider, :gitea, account: account) }
  let!(:gitea_credential) do
    create(:git_provider_credential, :gitea, account: account, provider: gitea_provider)
  end

  let(:node_template) { create(:system_node_template, account: account) }
  let(:node) { create(:system_node, account: account, node_template: node_template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  # Mark the node a genuine module-forge builder: assign the module to it.
  let(:module_forge_module) { create(:system_node_module, account: account, name: "module-forge") }
  let!(:module_forge_assignment) do
    create(:system_node_module_assignment, node: node, node_module: module_forge_module)
  end

  # The BUILD TARGET module (what's actually being built) — must exist as a
  # real NodeModule row; the endpoint 404s on an unknown slug (don't guess).
  let!(:target_module) { create(:system_node_module, account: account, name: "runtime-ruby") }

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

  def build_lease(status: "leased", purpose: "module_build", node_instance: instance)
    System::CiRunnerLease.create!(
      account: account,
      node_instance: node_instance,
      status: status,
      purpose: purpose
    )
  end

  let!(:lease) { build_lease }

  let(:path) { "/api/v1/system/node_api/config/ci_build_context" }

  def json
    JSON.parse(response.body)
  end

  def get_context(module_slug: "runtime-ruby")
    get path, params: { module: module_slug }, headers: headers
  end

  describe "happy path (genuine module-forge builder, active lease, Class-A module)" do
    it "returns the build context with the expected shape" do
      get_context

      expect(response).to have_http_status(:ok)

      data = json["data"]
      expect(data.keys).to contain_exactly(
        "source_repo_url", "source_token", "oras_registry", "oras_user",
        "oras_password", "apt_snapshot"
      )
      expect(data["source_repo_url"]).to eq("#{gitea_provider.effective_web_base_url}/powernode/powernode-system.git")
      expect(data["source_token"]).to eq("test_token_123")
      expect(data["oras_registry"]).to eq(URI.parse(gitea_provider.effective_web_base_url).host)
      expect(data["oras_user"]).to eq(gitea_credential.external_username)
      expect(data["oras_password"]).to eq("test_token_123")
    end

    it "NEVER includes parent_pat for a Class-A module" do
      get_context(module_slug: "runtime-ruby")

      expect(json["data"]).not_to have_key("parent_pat")
    end

    it "never returns any credential anywhere but the response body — the emitted fleet event carries ids only" do
      allow(::System::Fleet::EventBroadcaster).to receive(:emit!)

      get_context

      expect(::System::Fleet::EventBroadcaster).to have_received(:emit!) do |**kwargs|
        expect(kwargs[:kind]).to eq("system.ci_build_context_issued")
        expect(kwargs[:payload]).to eq(
          "instance_id" => instance.id,
          "lease_id"    => lease.id,
          "module_id"   => target_module.id
        )
        expect(kwargs[:payload].to_s).not_to include("test_token_123")
      end
    end

    it "never leaks the source_token into source_repo_url" do
      get_context

      expect(json.dig("data", "source_repo_url")).not_to include("test_token_123")
    end
  end

  describe "Class-B module" do
    let!(:hub_backend_module) { create(:system_node_module, account: account, name: "powernode-hub-backend") }

    it "includes parent_pat, resolved from the same account Gitea credential" do
      get_context(module_slug: "powernode-hub-backend")

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "parent_pat")).to eq("test_token_123")
    end
  end

  describe "authorization gates (BOTH required, fail-closed 403)" do
    it "403s when the instance is NOT provisioned with module-forge, even with an active lease" do
      module_forge_assignment.destroy!

      get_context

      expect(response).to have_http_status(:forbidden)
    end

    it "403s when module-forge IS present but there is no active module_build lease" do
      lease.destroy!

      get_context

      expect(response).to have_http_status(:forbidden)
    end

    it "403s when the only lease for this instance has already been released" do
      lease.update!(status: "released")

      get_context

      expect(response).to have_http_status(:forbidden)
    end

    it "403s when the only active lease is for a DIFFERENT purpose" do
      lease.update!(purpose: "generic")

      get_context

      expect(response).to have_http_status(:forbidden)
    end

    it "403s when the active module_build lease belongs to a DIFFERENT instance" do
      other_node = create(:system_node, account: account, node_template: node_template)
      other_instance = create(:system_node_instance, :running, node: other_node)
      lease.update!(node_instance: other_instance)

      get_context

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "module param validation" do
    it "422s when module is missing" do
      get path, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s for an unknown module slug" do
      get_context(module_slug: "does-not-exist")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "credential resolution failures" do
    it "404s when the account has no active Gitea credential" do
      gitea_credential.update!(is_active: false)

      get_context

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "registry configuration failure" do
    it "503s when the OCI registry is not configured" do
      allow(::System::DiskImageRegistryConfig).to receive(:configured?).and_return(false)

      get_context

      expect(response).to have_http_status(:service_unavailable)
    end
  end

  it "returns 401 without mTLS auth" do
    get path, params: { module: "runtime-ruby" }

    expect(response).to have_http_status(:unauthorized)
  end
end
