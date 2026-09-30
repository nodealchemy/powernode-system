# frozen_string_literal: true

require "rails_helper"
require "open3"

# IMP-1e5db5e6aefb — registering an SSH GitOps remote records the host key the
# sync will verify against: an explicit `ssh_host_key` when the operator has
# one, else an ssh-keyscan of the remote's host and port. The response carries
# the fingerprint(s) so the operator can check them against the git host.
# A hostile value is refused whole; nothing but a validated public key line
# ever reaches the column.
RSpec.describe "Operator API — GitOps repository host key", type: :request do
  let(:account) { create(:account) }
  let(:user)    { user_with_permissions("system.gitops.write", "system.gitops.read", account: account) }
  let(:headers) { auth_headers_for(user) }
  let(:entry) { SshHostKeyFixtures.entry("ssh-ed25519") }
  let(:fingerprint) { SshHostKeyFixtures.fingerprint(entry["key"]) }
  let(:scans) { [] }
  let(:keyscan_stdout) { "" }

  before do
    allow(Open3).to receive(:capture3) do |*argv|
      scans << argv.map(&:to_s)
      [ keyscan_stdout, "", instance_double(Process::Status, success?: true, exitstatus: 0) ]
    end
  end

  def register(attrs)
    payload = { gitops_repository: { name: "fleet-#{SecureRandom.hex(3)}", branch: "main", path_prefix: "",
                                     enabled: true, auto_apply: false }.merge(attrs) }
    post "/api/v1/system/gitops_repositories", params: payload.to_json, headers: headers
  end

  describe "POST /api/v1/system/gitops_repositories with an explicit ssh_host_key" do
    it "records the key, returns its fingerprint, and does not scan" do
      register(repo_url: "ssh://git@git.example.test:2222/fleet.git",
               ssh_host_key: "#{entry['type']} #{entry['key']}")

      expect(response).to have_http_status(:created)
      body = json_response.dig("data", "gitops_repository")
      expect(body["ssh_host_key_fingerprints"]).to eq([ fingerprint ])
      expect(body["ssh_host_key_source"]).to eq("explicit")
      expect(body.to_json).not_to include(entry["key"])

      repo = ::System::GitopsRepository.find(body["id"])
      expect(::System::Gitops::RepositoryHostKey.recorded_for(repo).map { |e| e["fingerprint"] }).to eq([ fingerprint ])
      expect(scans).to be_empty
    end

    it "refuses a newline-injected value and registers nothing" do
      injected = "#{entry['type']} #{entry['key']}\n@cert-authority * ssh-ed25519 #{SshHostKeyFixtures.key}"

      expect {
        register(repo_url: "git@git.example.test:fleet.git", ssh_host_key: injected)
      }.not_to change(::System::GitopsRepository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response["error"].to_s).to match(/ssh_host_key/)
    end

    it "refuses a private-key-shaped value and never echoes it" do
      pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nc2VudGluZWwtbm90LWEta2V5\n-----END OPENSSH PRIVATE KEY-----"

      expect {
        register(repo_url: "git@git.example.test:fleet.git", ssh_host_key: pem)
      }.not_to change(::System::GitopsRepository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include("c2VudGluZWw", "PRIVATE KEY")
    end
  end

  describe "POST without ssh_host_key" do
    context "for an ssh remote" do
      let(:keyscan_stdout) { "[git.example.test]:2222 #{entry['type']} #{entry['key']}\n" }

      it "scans the remote's host and port and records what normalizes" do
        register(repo_url: "ssh://git@git.example.test:2222/fleet.git")

        expect(response).to have_http_status(:created)
        expect(scans).to eq([ [ "ssh-keyscan", "-T", ::System::Gitops::RepositoryHostKey::KEYSCAN_TIMEOUT_SECONDS.to_s,
                                "-p", "2222", "git.example.test" ] ])
        body = json_response.dig("data", "gitops_repository")
        expect(body["ssh_host_key_fingerprints"]).to eq([ fingerprint ])
        expect(body["ssh_host_key_source"]).to eq("keyscan")
      end
    end

    context "for an ssh remote whose scan yields nothing" do
      it "registers with no key (the next sync pins on first use) and says so" do
        register(repo_url: "git@git.example.test:fleet.git")

        expect(response).to have_http_status(:created)
        body = json_response.dig("data", "gitops_repository")
        expect(body["ssh_host_key_fingerprints"]).to eq([])
        expect(body["ssh_host_key_source"]).to be_nil
      end
    end

    context "for an https remote" do
      it "neither scans nor records" do
        register(repo_url: "https://git.example.test/fleet.git")

        expect(response).to have_http_status(:created)
        expect(scans).to be_empty
        expect(json_response.dig("data", "gitops_repository", "ssh_host_key_fingerprints")).to eq([])
      end
    end
  end

  describe "PATCH /api/v1/system/gitops_repositories/:id" do
    let(:repo) { create(:system_gitops_repository, account: account, repo_url: "git@git.example.test:fleet.git") }

    it "replaces the recorded key with an explicit one (the operator's recovery from a mismatch)" do
      ::System::Gitops::RepositoryHostKey.record!(repo, [ SshHostKeyFixtures.entry ], source: "tofu")

      patch "/api/v1/system/gitops_repositories/#{repo.id}",
            params: { gitops_repository: { ssh_host_key: "#{entry['type']} #{entry['key']}" } }.to_json,
            headers: headers

      expect(response).to have_http_status(:ok)
      expect(json_response.dig("data", "gitops_repository", "ssh_host_key_fingerprints")).to eq([ fingerprint ])
      expect(repo.reload.ssh_host_keys["source"]).to eq("explicit")
    end

    it "refuses a hostile replacement and keeps the recorded key" do
      ::System::Gitops::RepositoryHostKey.record!(repo, [ entry ], source: "tofu")

      patch "/api/v1/system/gitops_repositories/#{repo.id}",
            params: { gitops_repository: { ssh_host_key: "ssh-ed25519 not base64!" } }.to_json,
            headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(::System::Gitops::RepositoryHostKey.recorded_for(repo.reload).map { |e| e["fingerprint"] }).to eq([ fingerprint ])
    end

    it "leaves the recorded key alone when ssh_host_key is not sent" do
      ::System::Gitops::RepositoryHostKey.record!(repo, [ entry ], source: "tofu")

      patch "/api/v1/system/gitops_repositories/#{repo.id}",
            params: { gitops_repository: { branch: "release" } }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      expect(repo.reload.branch).to eq("release")
      expect(repo.ssh_host_keys["source"]).to eq("tofu")
    end
  end

  describe "GET /api/v1/system/gitops_repositories/:id" do
    it "shows the recorded fingerprints and never the key blob" do
      repo = create(:system_gitops_repository, account: account, repo_url: "git@git.example.test:fleet.git")
      ::System::Gitops::RepositoryHostKey.record!(repo, [ entry ], source: "explicit")

      get "/api/v1/system/gitops_repositories/#{repo.id}", headers: headers

      expect(response).to have_http_status(:ok)
      body = json_response.dig("data", "gitops_repository")
      expect(body["ssh_host_key_fingerprints"]).to eq([ fingerprint ])
      expect(body["ssh_host_key_recorded_at"]).to be_present
      expect(response.body).not_to include(entry["key"])
    end
  end
end
