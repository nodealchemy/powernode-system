# frozen_string_literal: true

require "rails_helper"

# IMP-0f914db2c7cf — an operator whose GitOps sync fails on credentials had no
# platform-side way to see WHICH Vault path the repository is configured with,
# nor which keys that path is expected to hold. Both serializers accepted
# `vault_credential_path` on write and dropped it on read, and the required-key
# set existed only as two string literals buried in RepoSyncService#build_git_env.
#
# `vault_credential_path` is a PATH, not credential material — echoing it is
# safe. `required_credential_keys` is a set of key NAMES, likewise safe, and it
# is the input the core probe (POST /api/v1/admin_settings/vault/test with a
# `path`) compares against what the payload actually holds.
#
# The property that matters is not that the model has the method: it is that
# the SYNC PATH and the ADVERTISED requirement are the same definition. A
# serializer that advertises a key set the sync path does not enforce is a
# second false reassurance, which is the failure this whole thread started
# from. The last describe block pins that by mutating the producer and
# demanding the consumer's failure follow it.
RSpec.describe "Operator API — GitOps credential surface", type: :request do
  let(:account) { create(:account) }
  let(:user)    { user_with_permissions("system.gitops.read", account: account) }
  let(:headers) { auth_headers_for(user) }

  def repo_with(url:, path: "secret/data/powernode/gitops/deploy")
    ::System::GitopsRepository.create!(
      account: account, name: "fleet-#{SecureRandom.hex(4)}",
      repo_url: url, branch: "main", path_prefix: "",
      enabled: true, auto_apply: false, vault_credential_path: path
    )
  end

  describe "System::GitopsRepository#required_credential_keys" do
    it "requires the ssh_key for a scp-style SSH remote" do
      expect(repo_with(url: "git@git.example.test:powernode/fleet.git").required_credential_keys)
        .to eq(%w[ssh_key])
    end

    it "requires the ssh_key for an ssh:// remote" do
      expect(repo_with(url: "ssh://git@git.example.test/fleet.git").required_credential_keys)
        .to eq(%w[ssh_key])
    end

    # An anonymous public clone reads no Vault at all, so advertising a
    # requirement would send an operator probing a path the sync never opens.
    it "requires nothing when no credential path is configured" do
      expect(repo_with(url: "https://git.example.test/public.git", path: nil).required_credential_keys)
        .to eq([])
    end

    # Found by review. An HTTPS remote carrying NO userinfo makes git prompt for
    # the username FIRST, so the askpass shim has to answer it — which means the
    # payload needs a `username` too. Advertising only `password` for this shape
    # is the exact false green this surface exists to prevent: the probe says ok
    # and the clone still 401s.
    it "also requires the username for an HTTPS remote with no userinfo in the URL" do
      expect(repo_with(url: "https://git.example.test/fleet.git").required_credential_keys)
        .to eq(%w[password username])
    end

    it "requires only the password when the URL already carries the username" do
      expect(repo_with(url: "https://bot@git.example.test/fleet.git").required_credential_keys)
        .to eq(%w[password])
    end

    # Distinct from []. A repository configured WITH a credential path whose
    # scheme matches neither auth branch is silently cloned anonymously — the
    # path is dropped. Reporting [] would label the one repo whose credentials
    # ARE being ignored as the one needing none.
    it "reports nil, not [], for a configured path on an unsupported scheme" do
      expect(repo_with(url: "rsync://git.example.test/fleet.git").required_credential_keys)
        .to be_nil
    end
  end

  # Found by review. The shim ignored its argument and echoed the password for
  # EVERY prompt, so a userinfo-less HTTPS clone authenticated as
  # `<password>:<password>` and the Vault `username` was read and discarded.
  describe "the askpass shim answers each git prompt correctly" do
    let(:repository) { repo_with(url: "https://git.example.test/fleet.git") }
    let(:script) { "#{Rails.root.join('tmp/gitops', account.id.to_s, repository.id.to_s)}.askpass" }
    let(:captured) { {} }

    before do
      allow(::Security::VaultClient).to receive(:read_secret).and_return(
        { "username" => "deploy-bot", "password" => "hunter2" }.with_indifferent_access
      )
      allow(Open3).to receive(:capture3) do |*_args|
        # Read the shim while it still exists — run_git! deletes it on exit,
        # and sync! runs git a second time (rev-parse) after that cleanup, so
        # capture only on the first invocation.
        unless captured.key?(:username)
          captured[:username] = `bash #{script} "Username for 'https://git.example.test': "`.strip
          captured[:password] = `bash #{script} "Password for 'https://deploy-bot@git.example.test': "`.strip
        end
        [ "", "", instance_double(Process::Status, success?: true, exitstatus: 0) ]
      end
    end

    it "answers the Username prompt with the Vault username" do
      ::System::Gitops::RepoSyncService.sync!(repository)

      expect(captured[:username]).to eq("deploy-bot")
    end

    it "answers the Password prompt with the Vault password" do
      ::System::Gitops::RepoSyncService.sync!(repository)

      expect(captured[:password]).to eq("hunter2")
    end
  end

  describe "GET /api/v1/system/gitops_repositories/:id (serialize_repo)" do
    it "echoes the configured Vault path and the keys that path must hold" do
      repo = repo_with(url: "git@git.example.test:powernode/fleet.git")

      get "/api/v1/system/gitops_repositories/#{repo.id}", headers: headers

      expect(response).to have_http_status(:ok)
      serialized = response.parsed_body.dig("data", "gitops_repository")
      expect(serialized["vault_credential_path"]).to eq("secret/data/powernode/gitops/deploy")
      expect(serialized["required_credential_keys"]).to eq(%w[ssh_key])
    end

    it "reports an empty requirement for an anonymous repository" do
      repo = repo_with(url: "https://git.example.test/public.git", path: nil)

      get "/api/v1/system/gitops_repositories/#{repo.id}", headers: headers

      serialized = response.parsed_body.dig("data", "gitops_repository")
      expect(serialized["vault_credential_path"]).to be_nil
      expect(serialized["required_credential_keys"]).to eq([])
    end
  end

  describe "GET /api/v1/system/gitops_repositories (index)" do
    it "echoes both fields in the list projection too" do
      repo_with(url: "https://git.example.test/fleet.git")

      get "/api/v1/system/gitops_repositories", headers: headers

      listed = response.parsed_body.dig("data", "gitops_repositories").first
      expect(listed).to include("vault_credential_path" => "secret/data/powernode/gitops/deploy",
                                "required_credential_keys" => %w[password username])
    end
  end

  describe "MCP serialize_gitops_repository" do
    let(:tool) { ::Ai::Tools::SystemFleetTool.new(account: account, user: user) }

    it "echoes the path and the required key names" do
      repo = repo_with(url: "https://git.example.test/fleet.git")

      serialized = tool.send(:serialize_gitops_repository, repo)

      expect(serialized[:vault_credential_path]).to eq("secret/data/powernode/gitops/deploy")
      expect(serialized[:required_credential_keys]).to eq(%w[password username])
    end
  end

  # THE DIVERGENCE GUARD. The requirement the API advertises has to be the same
  # object the sync path enforces, otherwise the two drift and the probe built
  # on the advertised set reports "ok" for a payload the sync will reject.
  #
  # Mutating the PRODUCER (the model) and demanding the CONSUMER's failure name
  # the mutated key is the only assertion that can tell a shared definition from
  # two literals that happen to agree today.
  describe "RepoSyncService enforces the ADVERTISED key set, not a literal" do
    let(:repository) { repo_with(url: "https://git.example.test/fleet.git") }

    before do
      allow(::Security::VaultClient).to receive(:read_secret)
        .and_return({ "username" => "deploy-bot", "password" => "hunter2" }.with_indifferent_access)
      allow(Open3).to receive(:capture3).and_return(
        [ "", "", instance_double(Process::Status, success?: true, exitstatus: 0) ]
      )
    end

    it "fails naming a key the model newly requires, though no literal mentions it" do
      allow(repository).to receive(:required_credential_keys).and_return(%w[deploy_token])

      result = ::System::Gitops::RepoSyncService.sync!(repository)

      expect(result.ok?).to be(false)
      expect(result.error).to include("CredentialShapeError", "deploy_token")
    end

    it "never echoes a credential VALUE in the shape error" do
      allow(repository).to receive(:required_credential_keys).and_return(%w[deploy_token])

      expect(::System::Gitops::RepoSyncService.sync!(repository).error).not_to include("hunter2")
    end

    # The SSH arm reads the same producer and needs its own mutation: a guard
    # proven on one branch says nothing about the other.
    it "follows the producer on the SSH branch too" do
      ssh_repo = repo_with(url: "git@git.example.test:powernode/fleet.git")
      allow(ssh_repo).to receive(:required_credential_keys).and_return(%w[deploy_token])

      result = ::System::Gitops::RepoSyncService.sync!(ssh_repo)

      expect(result.ok?).to be(false)
      expect(result.error).to include("CredentialShapeError", "deploy_token")
    end

    # Fail CLOSED on an empty contract. Today unreachable — the scheme dispatch
    # lives in the model and every arm that reaches require_creds! has keys —
    # but the coupling between build_git_env's branches and the model's is by
    # convention, so an empty set must refuse rather than wave the clone
    # through with no credential check at all.
    it "refuses rather than enforcing nothing when the contract is empty" do
      allow(repository).to receive(:required_credential_keys).and_return([])

      result = ::System::Gitops::RepoSyncService.sync!(repository)

      expect(result.ok?).to be(false)
      expect(result.error).to include("CredentialShapeError")
    end
  end
end
