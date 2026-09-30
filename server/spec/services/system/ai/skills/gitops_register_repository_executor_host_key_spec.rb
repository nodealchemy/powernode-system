# frozen_string_literal: true

require "rails_helper"
require "open3"

# IMP-1e5db5e6aefb — the skill door records the host key the same way the
# REST door does: an explicit `ssh_host_key` is validated before the approval
# gate (a hostile value can only ever fail, so no approval is parked for it);
# without one, an SSH remote is keyscanned in #perform, after approval. The
# envelope carries fingerprints only.
RSpec.describe System::Ai::Skills::GitopsRegisterRepositoryExecutor, "host key" do
  let(:account) { create(:account) }
  let(:exec)    { described_class.new(account: account) }
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

  it "declares the optional ssh_host_key input and the fingerprint output" do
    d = described_class.descriptor
    expect(d[:inputs][:ssh_host_key]).to include(type: "string", required: false)
    expect(d[:outputs]).to include(ssh_host_key_fingerprints: :array)
  end

  describe "#execute (policy auto-executes)" do
    before { auto_execute_skill_policy!(account, described_class) }

    it "records an explicit key and returns its fingerprint, without scanning" do
      r = exec.execute(name: "fleet-config", repo_url: "ssh://git@git.example.test:2222/fleet.git",
                       ssh_host_key: "#{entry['type']} #{entry['key']}")

      expect(r[:success]).to be true
      expect(r.dig(:data, :ssh_host_key_fingerprints)).to eq([ fingerprint ])
      expect(r.to_json).not_to include(entry["key"])
      repo = ::System::GitopsRepository.find(r.dig(:data, :repository_id))
      expect(repo.ssh_host_keys["source"]).to eq("explicit")
      expect(scans).to be_empty
    end

    context "without an explicit key" do
      let(:keyscan_stdout) { "[git.example.test]:2222 #{entry['type']} #{entry['key']}\n" }

      it "scans the remote and records what normalizes" do
        r = exec.execute(name: "fleet-config", repo_url: "ssh://git@git.example.test:2222/fleet.git")

        expect(r[:success]).to be true
        expect(scans).to eq([ [ "ssh-keyscan", "-T", ::System::Gitops::RepositoryHostKey::KEYSCAN_TIMEOUT_SECONDS.to_s,
                                "-p", "2222", "git.example.test" ] ])
        expect(r.dig(:data, :ssh_host_key_fingerprints)).to eq([ fingerprint ])
        repo = ::System::GitopsRepository.find(r.dig(:data, :repository_id))
        expect(repo.ssh_host_keys["source"]).to eq("keyscan")
      end
    end

    it "does not scan an https remote" do
      r = exec.execute(name: "fleet-config", repo_url: "https://git.example.test/fleet.git")

      expect(r[:success]).to be true
      expect(r.dig(:data, :ssh_host_key_fingerprints)).to eq([])
      expect(scans).to be_empty
    end
  end

  describe "admission before the approval gate" do
    it "refuses a hostile ssh_host_key without parking an approval, and never echoes it" do
      pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nc2VudGluZWwtbm90LWEta2V5\n-----END OPENSSH PRIVATE KEY-----"

      expect {
        r = exec.execute(name: "fleet-config", repo_url: "git@git.example.test:fleet.git", ssh_host_key: pem)
        expect(r[:success]).to be false
        expect(r[:pending]).to be_falsey
        expect(r[:error]).to match(/ssh_host_key/)
        expect(r[:error]).not_to include("c2VudGluZWw", "PRIVATE")
      }.not_to change { ::System::GitopsRepository.where(account_id: account.id).count }

      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
    end
  end
end
