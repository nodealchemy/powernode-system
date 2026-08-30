# frozen_string_literal: true

require "rails_helper"

# Guards the Vault-credential boundary for GitOps repository sync.
#
# The vault gem parses EVERY response with `symbolize_names: true`
# (vault-0.20.1 lib/vault/client.rb JSON_PARSE_OPTIONS), so
# Security::VaultClient#read_secret's no-key branch hands back a SYMBOL-keyed
# Hash while RepoSyncService#build_git_env indexed it with STRINGS. A
# wrong-keyed Hash is truthy and non-empty, so `return {} unless creds` passed
# it straight through and the two auth branches then diverged into symptoms
# that look like anything but a credential problem:
#
#   * HTTPS is nil-TOLERANT (`password.to_s`) -> authenticates with a BLANK
#     password; the operator sees a plain auth failure.
#   * SSH is nil-FRAGILE (`nil.end_with?`) -> NoMethodError, written verbatim
#     into GitopsSyncRun#error_message by sync!'s blanket rescue.
#
# So the fixtures below are SYMBOL-keyed on purpose (a string-keyed fixture is
# exactly how this survived) and they drive the REAL Security::VaultClient —
# only the vault gem's logical reader is doubled. Stubbing `.read_secret`
# itself would test the fixture, not the boundary.
#
# NEVER contacts a real Vault server: `token:` short-circuits the AppRole login.
RSpec.describe System::Gitops::RepoSyncService do
  let(:account) { create(:account) }
  let(:vault_path) { "secret/data/powernode/gitops/#{SecureRandom.hex(6)}" }

  # Exactly the shape Security::VaultClient#extract_secret_data yields for a
  # KV v2 response: symbol keys, all the way down.
  let(:vault_payload) do
    { username: "deploy-bot", password: "pat-#{SecureRandom.hex(4)}", ssh_key: "KEYBODY-#{SecureRandom.hex(4)}" }
  end

  # A real Security::VaultClient whose vault-gem handle is a double. The
  # normalization under test lives in #read_secret, so it must run for real.
  let(:vault_client) do
    Security::VaultClient.new(token: "spec-token").tap do |client|
      logical = double("Vault::Logical")
      allow(logical).to receive(:read).with(vault_path).and_return(
        double("Vault::Secret", data: { data: vault_payload })
      )
      client.instance_variable_set(:@client, double("Vault::Client", logical: logical))
    end
  end

  # Every Open3.capture3 invocation, as {env:, argv:}, plus the CONTENT of the
  # one-shot secret files read at invocation time — run_git!'s `ensure` deletes
  # them, so reading them afterwards is not possible.
  let(:invocations) { [] }
  let(:secret_files) { {} }

  # The invocation that carries git auth: clone/fetch, not read_commit_sha's
  # bare `git rev-parse` (which run_git! does not route through build_git_env).
  def clone_invocation
    invocations.find { |inv| inv[:argv].include?("clone") }
  end

  before do
    allow(Security::VaultClient).to receive(:instance).and_return(vault_client)
    allow(Open3).to receive(:capture3) do |*args, **_kwargs|
      env = args.first.is_a?(Hash) ? args.first : {}
      argv = args.first.is_a?(Hash) ? args[1..] : args
      invocations << { env: env, argv: argv.map(&:to_s) }
      secret_files[:askpass] = File.read(env["GIT_ASKPASS"]) if env["GIT_ASKPASS"]
      if (match = env["GIT_SSH_COMMAND"].to_s.match(/-i (\S+)/))
        secret_files[:ssh_key] = File.read(match[1])
      end
      [ "abc123\n", "", instance_double(Process::Status, success?: true, exitstatus: 0) ]
    end
  end

  describe "#sync! credential plumbing (HTTPS)" do
    let(:repository) do
      create(:system_gitops_repository,
             account: account,
             repo_url: "https://git.example.test/powernode/fleet-config.git",
             vault_credential_path: vault_path)
    end

    it "writes the Vault PASSWORD into the one-shot askpass script" do
      expect(described_class.sync!(repository).ok?).to be(true)

      expect(secret_files[:askpass]).to include(vault_payload[:password])
    end

    it "sets GIT_ASKPASS and suppresses the terminal prompt" do
      described_class.sync!(repository)

      expect(clone_invocation[:env]).to include("GIT_TERMINAL_PROMPT" => "0")
      expect(clone_invocation[:env]["GIT_ASKPASS"]).to be_present
    end
  end

  describe "#sync! credential plumbing (SSH)" do
    let(:repository) do
      create(:system_gitops_repository,
             account: account,
             repo_url: "git@git.example.test:powernode/fleet-config.git",
             vault_credential_path: vault_path)
    end

    it "writes the Vault SSH KEY into the one-shot key file" do
      expect(described_class.sync!(repository).ok?).to be(true)

      expect(secret_files[:ssh_key]).to eq("#{vault_payload[:ssh_key]}\n")
    end

    it "points GIT_SSH_COMMAND at that key file" do
      described_class.sync!(repository)

      expect(clone_invocation[:env]["GIT_SSH_COMMAND"]).to match(/\Assh -i \S+ -o StrictHostKeyChecking=no -o IdentitiesOnly=yes\z/)
    end
  end

  # The shape guard. Before it, a payload missing the key a branch needs
  # produced a blank-password auth attempt (HTTPS) or a NoMethodError (SSH) —
  # neither of which reads as "the credential payload is wrong".
  describe "wrong-shaped credential payload" do
    let(:vault_payload) { { user: "deploy-bot", token: "not-the-key-we-need" } }

    shared_examples "an honest shape failure" do
      it "fails with a credential-shape error naming the MISSING key" do
        result = described_class.sync!(repository)

        expect(result.ok?).to be(false)
        expect(result.error).to include("CredentialShapeError")
        expect(result.error).to match(/#{Regexp.escape(missing_key)}/)
      end

      it "names the keys that ARE present, and never a credential VALUE" do
        result = described_class.sync!(repository)

        expect(result.error).to include("token", "user")
        expect(result.error).not_to include(vault_payload[:token])
      end

      it "does not invoke git at all" do
        described_class.sync!(repository)

        expect(invocations).to be_empty
      end
    end

    context "HTTPS (previously: authenticated with a blank password)" do
      let(:repository) do
        create(:system_gitops_repository,
               account: account,
               repo_url: "https://git.example.test/powernode/fleet-config.git",
               vault_credential_path: vault_path)
      end
      let(:missing_key) { "password" }

      it_behaves_like "an honest shape failure"
    end

    context "SSH (previously: NoMethodError on nil.end_with?)" do
      let(:repository) do
        create(:system_gitops_repository,
               account: account,
               repo_url: "git@git.example.test:powernode/fleet-config.git",
               vault_credential_path: vault_path)
      end
      let(:missing_key) { "ssh_key" }

      it_behaves_like "an honest shape failure"

      it "does not surface a NoMethodError" do
        expect(described_class.sync!(repository).error).not_to include("NoMethodError")
      end
    end

    # A PRESENT but empty value is the same failure wearing a different mask:
    # `password.to_s` is already "" for a nil, so a key whose value is blank
    # reproduces the blank-password auth attempt exactly. Key presence is not
    # the property; a usable value is.
    context "the key is present but BLANK" do
      let(:vault_payload) { { username: "deploy-bot", password: "" } }
      let(:repository) do
        create(:system_gitops_repository,
               account: account,
               repo_url: "https://git.example.test/powernode/fleet-config.git",
               vault_credential_path: vault_path)
      end

      it "still fails with a credential-shape error rather than authenticating blank" do
        result = described_class.sync!(repository)

        expect(result.ok?).to be(false)
        expect(result.error).to include("CredentialShapeError", "password")
        expect(invocations).to be_empty
      end
    end
  end

  describe "anonymous clone" do
    let(:repository) do
      create(:system_gitops_repository,
             account: account,
             repo_url: "https://git.example.test/powernode/public.git",
             vault_credential_path: nil)
    end

    it "passes an empty env and never reads Vault" do
      expect(Security::VaultClient).not_to receive(:read_secret)

      expect(described_class.sync!(repository).ok?).to be(true)
      expect(clone_invocation[:env]).to eq({})
    end
  end
end
