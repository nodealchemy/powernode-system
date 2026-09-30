# frozen_string_literal: true

require "rails_helper"

# IMP-1e5db5e6aefb — a GitOps repository's remote and branch are operator
# input that reach git's argv and decide which transport git runs. The
# model admits only the two remote forms the sync builds an environment
# for (https://, and an ssh endpoint System::Gitops::SshRemote can parse),
# and a branch git will take as a ref name rather than an option.
RSpec.describe System::GitopsRepository, type: :model do
  let(:account) { create(:account) }

  def repo(attrs)
    described_class.new({ account: account, name: "fleet-#{SecureRandom.hex(3)}", branch: "main",
                          path_prefix: "", enabled: true, auto_apply: false, last_status: "pending" }.merge(attrs))
  end

  describe "repo_url" do
    it "accepts https:// and both ssh forms" do
      expect(repo(repo_url: "https://git.example.test/fleet.git")).to be_valid
      expect(repo(repo_url: "ssh://git@git.example.test:2222/fleet.git")).to be_valid
      expect(repo(repo_url: "deploy@git.example.test:powernode/fleet.git")).to be_valid
    end

    # git routes these to ssh itself (git-builtin transports), so the sync
    # would run the PATH ssh with the rails user's config and known_hosts —
    # outside the per-repository pin. Refused rather than parsed: no legacy
    # spellings.
    it "refuses git+ssh:// and ssh+git://" do
      %w[git+ssh://git.example.test/fleet.git ssh+git://git.example.test/fleet.git].each do |url|
        record = repo(repo_url: url)

        expect(record).not_to be_valid, url
        expect(record.errors[:repo_url].join).to match(/https:\/\/|ssh/)
      end
    end

    it "refuses cleartext, local and unparseable remotes" do
      [
        "git://git.example.test/fleet.git",
        "http://git.example.test/fleet.git",
        "file:///srv/git/fleet.git",
        "/srv/git/fleet.git",
        "rsync://git.example.test/fleet.git",
        "ssh://-evil/fleet.git",
        "git@-evil:fleet.git"
      ].each do |url|
        expect(repo(repo_url: url)).not_to be_valid, url
      end
    end
  end

  describe "#required_credential_keys" do
    # The credential contract and the sync's transport dispatch must agree on
    # what an ssh remote IS; a user other than `git` is still ssh.
    it "requires ssh_key for any parseable ssh endpoint, whatever the user" do
      expect(repo(repo_url: "deploy@git.example.test:fleet.git",
                  vault_credential_path: "secret/data/gitops/x").required_credential_keys).to eq(%w[ssh_key])
      expect(repo(repo_url: "ssh://git.example.test/fleet.git",
                  vault_credential_path: "secret/data/gitops/x").required_credential_keys).to eq(%w[ssh_key])
    end

    it "reports nil for a configured path on a remote the sync refuses" do
      expect(repo(repo_url: "git+ssh://git.example.test/fleet.git",
                  vault_credential_path: "secret/data/gitops/x").required_credential_keys).to be_nil
    end
  end

  describe "branch" do
    it "accepts ordinary and slashed branch names" do
      expect(repo(repo_url: "https://git.example.test/fleet.git", branch: "main")).to be_valid
      expect(repo(repo_url: "https://git.example.test/fleet.git", branch: "release/1.2")).to be_valid
      expect(repo(repo_url: "https://git.example.test/fleet.git", branch: "feature-x_1")).to be_valid
    end

    # A dash-prefixed branch is an OPTION to `git clone --branch` / `git fetch`.
    it "refuses a branch that starts with '-'" do
      record = repo(repo_url: "https://git.example.test/fleet.git", branch: "--upload-pack=touch /tmp/x")

      expect(record).not_to be_valid
      expect(record.errors[:branch]).to be_present
    end

    it "refuses names git's ref-format rule rejects" do
      [ "a..b", "a b", "a/", "/a", "a//b", "a.lock", "a:b", "a~1", "a^", "a?", "a*", "a[b", "a\\b", ".a", "a/.b", "@", "a@{b", "a." ].each do |name|
        expect(repo(repo_url: "https://git.example.test/fleet.git", branch: name)).not_to be_valid, name
      end
    end
  end
end
