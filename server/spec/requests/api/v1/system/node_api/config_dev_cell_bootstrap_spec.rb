# frozen_string_literal: true

require "rails_helper"

# Dev-cell bootstrap — the mTLS-authenticated instance-side read path for
# GET /api/v1/system/node_api/config/dev_cell_bootstrap.
#
# Redesigned (A1' security rework): NO account-wide secret is minted. The action
# is GATED to instances actually provisioned with the dev-cell module (mTLS
# enrollment alone is not enough). The MCP half returns { mcp_url } only and
# grants the peer the dev-cell tool set (dev-loop + MCP-first) — only AFTER Gitea fully
# succeeds (fail-closed ordering). The Gitea half returns a per-repo read-WRITE
# Ed25519 DEPLOY KEY on ONLY the source repo, issued only after develop/master
# branch protection is confirmed and the private key is confirmed stored in
# Vault.
#
# SECURITY: these specs assert only the PRESENCE/SHAPE of the deploy-key private
# key — never its value.
RSpec.describe "Api::V1::System::NodeApi::Config#dev_cell_bootstrap", type: :request do
  let(:account) { create(:account) }

  let(:gitea_provider) { create(:git_provider, :gitea, account: account) }
  let!(:gitea_credential) do
    create(:git_provider_credential,
           account: account, provider: gitea_provider, external_username: "pncell")
  end

  let(:node_template) { create(:system_node_template, account: account) }
  let(:node) { create(:system_node, account: account, node_template: node_template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  # Mark the node a genuine dev-cell: assign the dev-cell NodeModule to it.
  let(:dev_cell_module) { create(:system_node_module, account: account, name: "dev-cell") }
  let!(:dev_cell_assignment) do
    create(:system_node_module_assignment, node: node, node_module: dev_cell_module)
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

  let(:path) { "/api/v1/system/node_api/config/dev_cell_bootstrap" }
  let(:expected_ssh_url) { "git@gitea.example.com:powernode/powernode-platform.git" }

  # Vault store confirmed (:vault); the DB-fallback test overrides to
  # :database (Vault-less deployments — also a confirmed store, since
  # 20260720180000 gave System::DevCellDeployKey a real encrypted_credentials
  # column); the fail-closed test overrides to an unconfirmed shape.
  let(:vault_provider) { instance_double(Security::VaultCredentialProvider) }

  # Stub the Gitea client so no real HTTP is issued; assert on shape only.
  let(:fake_gitea_client) { instance_double("Devops::Git::GiteaApiClient") }

  before do
    allow(Security::VaultCredentialProvider).to receive(:new).and_return(vault_provider)
    allow(vault_provider).to receive(:store_credential)
      .and_return({ stored_in: :vault, path: "system/dev-cell-deploy-keys/x" })

    allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake_gitea_client)
    allow(fake_gitea_client).to receive(:update_branch_protection).and_return({ success: true })
    allow(fake_gitea_client).to receive(:get_branch_protection).and_return({ "enable_push" => false })
    allow(fake_gitea_client).to receive(:list_deploy_keys).and_return([])
    allow(fake_gitea_client).to receive(:delete_deploy_key).and_return({ success: true })
    allow(fake_gitea_client).to receive(:create_deploy_key).and_return(
      { success: true, key: { "id" => 7, "title" => "dev-cell-#{instance.id}", "read_only" => false } }
    )
    allow(fake_gitea_client).to receive(:get_repository).and_return({ "ssh_url" => expected_ssh_url })
  end

  def json
    JSON.parse(response.body)
  end

  describe "happy path (genuine dev-cell)" do
    it "returns the mcp + gitea bootstrap bundle" do
      get path, headers: headers

      expect(response).to have_http_status(:ok)

      mcp = json.dig("data", "mcp")
      expect(mcp.keys).to contain_exactly("mcp_url")
      expect(mcp["mcp_url"]).to end_with("/mcp/message")

      gitea = json.dig("data", "gitea")
      expect(gitea["clone_url"]).to eq(expected_ssh_url)
      expect(gitea["private_key"]).to start_with("-----BEGIN OPENSSH PRIVATE KEY-----") # shape only
      expect(gitea).to have_key("known_hosts")
    end

    it "announces the peer and grants the dev-cell tool set (dev-loop + MCP-first)" do
      get path, headers: headers

      peer = System::NodeInstancePeer.find_by(node_instance_id: instance.id)
      expect(peer).to be_present
      # Exactly the server-defined grant — dev-loop plus the MCP-first recall +
      # contribute-back set (default-deny everything else). Asserted against the
      # constant so the two stay in lockstep.
      expect(peer.granted_mcp_tools).to contain_exactly(*System::DevCellBootstrapService::DEV_CELL_MCP_TOOLS)
      expect(peer.granted_mcp_tools).to include(
        "platform.dev_next_task", "platform.search_knowledge", "platform.create_learning"
      )
      # Curation/lifecycle + fleet mutation stay denied.
      expect(peer.granted_mcp_tools).not_to include("platform.delete_knowledge", "platform.delegate_ralph_task")
    end

    it "confirms develop/master protection BEFORE issuing a read-WRITE deploy key" do
      get path, headers: headers

      expect(fake_gitea_client).to have_received(:update_branch_protection)
        .with("powernode", "powernode-platform", "develop", hash_including(enable_push: false))
      expect(fake_gitea_client).to have_received(:update_branch_protection)
        .with("powernode", "powernode-platform", "master", hash_including(enable_push: false))
      expect(fake_gitea_client).to have_received(:get_branch_protection).with("powernode", "powernode-platform", "develop")
      expect(fake_gitea_client).to have_received(:get_branch_protection).with("powernode", "powernode-platform", "master")
      expect(fake_gitea_client).to have_received(:update_branch_protection)
        .with("powernode", "powernode-platform", "loop/*", hash_including(enable_push: true))

      expect(fake_gitea_client).to have_received(:create_deploy_key).with(
        "powernode", "powernode-platform", "dev-cell-#{instance.id}",
        a_string_starting_with("ssh-ed25519 "), read_only: false
      )
    end

    it "persists a DevCellDeployKey row (no plaintext key in the DB)" do
      expect { get path, headers: headers }
        .to change { System::DevCellDeployKey.where(node_instance_id: instance.id).count }.by(1)

      record = System::DevCellDeployKey.find_by(node_instance_id: instance.id)
      expect(record.deploy_key_id).to eq(7)
      expect(record.source_repo).to eq("powernode/powernode-platform")
      expect(record.attributes.values.map(&:to_s)).not_to include(a_string_including("OPENSSH PRIVATE KEY"))
    end

    it "rotate-on-bootstrap: deletes any prior deploy key of this instance's title" do
      allow(fake_gitea_client).to receive(:list_deploy_keys).and_return(
        [ { "id" => 99, "title" => "dev-cell-#{instance.id}" },
          { "id" => 12, "title" => "some-other-key" } ]
      )
      get path, headers: headers

      expect(fake_gitea_client).to have_received(:delete_deploy_key).with("powernode", "powernode-platform", 99)
      expect(fake_gitea_client).not_to have_received(:delete_deploy_key).with("powernode", "powernode-platform", 12)
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

    it "403s an mTLS instance whose node is NOT provisioned as a dev-cell — no side effects" do
      get path, headers: plain_headers

      expect(response).to have_http_status(:forbidden)
      expect(System::NodeInstancePeer.find_by(node_instance_id: plain_instance.id)).to be_nil
      expect(System::DevCellDeployKey.find_by(node_instance_id: plain_instance.id)).to be_nil
      expect(fake_gitea_client).not_to have_received(:create_deploy_key)
    end
  end

  describe "fail-closed behaviour" do
    it "does NOT commit the MCP grant when Gitea provisioning fails (grant is last)" do
      gitea_credential.update!(is_active: false) # no usable Gitea credential

      get path, headers: headers

      expect(response).to have_http_status(:service_unavailable)
      # build_mcp (announce + grant) never ran, so no peer / no grant persisted.
      expect(System::NodeInstancePeer.find_by(node_instance_id: instance.id)).to be_nil
    end

    it "503s and issues NO key when develop/master protection can't be confirmed" do
      allow(fake_gitea_client).to receive(:get_branch_protection).and_return(nil)

      get path, headers: headers

      expect(response).to have_http_status(:service_unavailable)
      expect(fake_gitea_client).not_to have_received(:create_deploy_key)
      expect(System::DevCellDeployKey.find_by(node_instance_id: instance.id)).to be_nil
      expect(System::NodeInstancePeer.find_by(node_instance_id: instance.id)).to be_nil
    end

    it "503s, rolls back, and deletes the orphan key when neither vault nor database confirm storage" do
      allow(vault_provider).to receive(:store_credential).and_return({ stored_in: :none })

      get path, headers: headers

      expect(response).to have_http_status(:service_unavailable)
      # Row rolled back; the Gitea key that was created gets deleted (fail-closed).
      expect(System::DevCellDeployKey.find_by(node_instance_id: instance.id)).to be_nil
      expect(fake_gitea_client).to have_received(:delete_deploy_key).with("powernode", "powernode-platform", 7)
      # Grant is last → never ran.
      expect(System::NodeInstancePeer.find_by(node_instance_id: instance.id)).to be_nil
    end

    it "succeeds on the Vault-less database fallback (encrypted_credentials, e.g. ops-hub)" do
      allow(vault_provider).to receive(:store_credential).and_return({ stored_in: :database })

      get path, headers: headers

      expect(response).to have_http_status(:ok)
      expect(System::DevCellDeployKey.find_by(node_instance_id: instance.id)).to be_present
      expect(fake_gitea_client).not_to have_received(:delete_deploy_key)
    end
  end

  it "returns 401 without mTLS auth" do
    get path
    expect(response).to have_http_status(:unauthorized)
  end
end
