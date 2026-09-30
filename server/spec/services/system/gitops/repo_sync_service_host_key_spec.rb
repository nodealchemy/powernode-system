# frozen_string_literal: true

require "rails_helper"
require "shellwords"

# IMP-1e5db5e6aefb — the GitOps clone/pull verifies the git host's identity.
#
# Before this, GIT_SSH_COMMAND carried StrictHostKeyChecking=no: the last
# unverified ssh in the system server, and the one whose remote content the
# reconciler then applies to the fleet. Now the sync connects only with the
# option set System::SshExecutionService#with_host_verification uses, against
# a per-call known_hosts holding this repository's recorded key(s):
#
#   * recorded key, host presents it        -> verified sync
#   * recorded key, host presents another   -> sync FAILS with the named
#     reason host_key_mismatch, the stored key is untouched, a HIGH event
#   * no recorded key                        -> ssh-keyscan, record (TOFU),
#     a LOW event, then the verified sync
#   * no recorded key and nothing to scan    -> refused, never unverified
#
# The ssh/keyscan boundary (Open3) is stubbed; nothing here reaches a network.
RSpec.describe System::Gitops::RepoSyncService, "host key verification" do
  let(:account) { create(:account) }
  let(:vault_path) { "secret/data/powernode/gitops/#{SecureRandom.hex(6)}" }
  let(:vault_payload) { { ssh_key: "KEYBODY-#{SecureRandom.hex(4)}" } }
  let(:vault_client) do
    Security::VaultClient.new(token: "spec-token").tap do |client|
      logical = double("Vault::Logical")
      allow(logical).to receive(:read).with(vault_path).and_return(
        double("Vault::Secret", data: { data: vault_payload })
      )
      client.instance_variable_set(:@client, double("Vault::Client", logical: logical))
    end
  end

  let(:entry) { SshHostKeyFixtures.entry("ssh-ed25519") }
  let(:fingerprint) { SshHostKeyFixtures.fingerprint(entry["key"]) }
  let(:repository) do
    create(:system_gitops_repository,
           account: account,
           repo_url: "ssh://git@git.example.test:2222/powernode/fleet-config.git",
           vault_credential_path: vault_path)
  end
  let(:host_alias) { System::Gitops::RepositoryHostKey.alias_for(repository) }

  # Every Open3 invocation as {argv:, env:}, plus what the per-call files held
  # at invocation time (run_git!'s ensure deletes them afterwards).
  let(:invocations) { [] }
  let(:known_hosts_seen) { {} }
  let(:keyscan_stdout) { "" }
  let(:git_response) { [ "abc123\n", "", instance_double(Process::Status, success?: true, exitstatus: 0) ] }

  def git_invocations
    invocations.select { |inv| inv[:argv].first == "git" }
  end

  def keyscan_invocations
    invocations.select { |inv| inv[:argv].first == "ssh-keyscan" }
  end

  def ssh_argv(inv)
    Shellwords.split(inv[:env].fetch("GIT_SSH_COMMAND"))
  end

  def record_key!
    System::Gitops::RepositoryHostKey.record!(repository, [ entry ], source: "explicit")
  end

  before do
    allow(Security::VaultClient).to receive(:instance).and_return(vault_client)
    allow(Open3).to receive(:capture3) do |*args, **_kwargs|
      env = args.first.is_a?(Hash) ? args.first : {}
      argv = (args.first.is_a?(Hash) ? args[1..] : args).map(&:to_s)
      invocations << { env: env, argv: argv }
      if argv.first == "ssh-keyscan"
        [ keyscan_stdout, "# banner\n", instance_double(Process::Status, success?: true, exitstatus: 0) ]
      else
        if env["GIT_SSH_COMMAND"] &&
           (option = ssh_argv(env: env).find { |a| a.start_with?("UserKnownHostsFile=") })
          file = option.delete_prefix("UserKnownHostsFile=")
          known_hosts_seen[:content] = File.read(file)
          known_hosts_seen[:mode] = File.stat(file).mode & 0o777
        end
        git_response
      end
    end
  end

  describe "a repository with a recorded key (verified path)" do
    before { record_key! }

    it "runs ssh with strict checking against a per-call known_hosts holding exactly the recorded line" do
      expect(described_class.sync!(repository).ok?).to be(true)

      argv = ssh_argv(git_invocations.first)
      known_hosts = argv.find { |a| a.start_with?("UserKnownHostsFile=") }.delete_prefix("UserKnownHostsFile=")
      key_file = argv[argv.index("-i") + 1]

      expect(argv).to eq([
        "ssh",
        "-F", "/dev/null",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=#{known_hosts}",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "HostKeyAlias=#{host_alias}",
        "-o", "CheckHostIP=no",
        "-o", "UpdateHostKeys=no",
        "-o", "VerifyHostKeyDNS=no",
        "-i", key_file,
        "-o", "IdentitiesOnly=yes"
      ])
      expect(argv).not_to include("StrictHostKeyChecking=no")
      expect(known_hosts_seen[:content]).to eq(System::SshHostKeys.known_hosts(host_alias, [ entry.merge("fingerprint" => fingerprint) ]))
      expect(known_hosts_seen[:mode]).to eq(0o600)
    end

    it "removes the known_hosts file after the call" do
      described_class.sync!(repository)

      argv = ssh_argv(git_invocations.first)
      known_hosts = argv.find { |a| a.start_with?("UserKnownHostsFile=") }.delete_prefix("UserKnownHostsFile=")
      expect(File.exist?(known_hosts)).to be(false)
    end

    it "does not scan the host" do
      described_class.sync!(repository)

      expect(keyscan_invocations).to be_empty
    end
  end

  # The spawned process is GIT, not ssh: git relays ssh's stderr and then
  # dies with its own exit code, 128 — ssh's 255 never reaches this service.
  # An earlier draft of the guard keyed on 255 and passed only because the
  # fixture said so; the fixture now says what git says.
  describe "a CHANGED host key (mismatch)" do
    let(:git_exit) { 128 }
    let(:git_response) do
      stderr = "Host key for #{host_alias} has changed and you have requested strict checking.\r\n" \
               "Host key verification failed.\r\nfatal: Could not read from remote repository.\n"
      [ "", stderr, instance_double(Process::Status, success?: false, exitstatus: git_exit) ]
    end

    before { record_key! }

    it "fails the sync with the named reason" do
      result = described_class.sync!(repository)

      expect(result.ok?).to be(false)
      expect(result.reason).to eq(described_class::HOST_KEY_MISMATCH_REASON)
      expect(result.error).to start_with("#{described_class::HOST_KEY_MISMATCH_REASON}:")
      expect(result.error).to include(fingerprint, "git.example.test", "2222")
    end

    it "leaves the stored key unchanged and never scans" do
      described_class.sync!(repository)

      expect(System::Gitops::RepositoryHostKey.recorded_for(repository.reload).map { |e| e["fingerprint"] })
        .to eq([ fingerprint ])
      expect(repository.ssh_host_keys["source"]).to eq("explicit")
      expect(keyscan_invocations).to be_empty
    end

    it "emits the mismatch event with the recorded fingerprints, never a key blob" do
      described_class.sync!(repository)

      event = System::FleetEvent.find_by(kind: System::Gitops::RepositoryHostKey::MISMATCH_EVENT_KIND,
                                         account_id: account.id)
      expect(event).to be_present
      expect(event.severity).to eq("high")
      expect(event.payload).to include("repository_id" => repository.id,
                                       "host" => "git.example.test", "port" => 2222,
                                       "recorded_fingerprints" => [ fingerprint ])
      expect(event.payload.to_json).not_to include(entry["key"])
    end

    it "records the named reason on the sync run through the reconciler" do
      run = repository.schedule_sync!
      result = System::Gitops::Reconciler.reconcile!(repository: repository, sync_run: run)

      expect(result.ok?).to be(false)
      expect(run.reload.status).to eq("failed")
      expect(run.error_message).to start_with("#{described_class::HOST_KEY_MISMATCH_REASON}:")
      expect(repository.reload.last_status).to eq("failed")
    end

    # A host that presents only key TYPES the recorded set lacks fails strict
    # checking with different wording; it still did not present a recorded key.
    it "classifies an unknown-type refusal as a mismatch too" do
      allow(Open3).to receive(:capture3) do |*args, **_kwargs|
        argv = (args.first.is_a?(Hash) ? args[1..] : args).map(&:to_s)
        invocations << { env: args.first.is_a?(Hash) ? args.first : {}, argv: argv }
        stderr = "No RSA host key is known for #{host_alias} and you have requested strict checking.\r\n" \
                 "Host key verification failed.\r\n"
        [ "", stderr, instance_double(Process::Status, success?: false, exitstatus: 128) ]
      end

      expect(described_class.sync!(repository).reason).to eq(described_class::HOST_KEY_MISMATCH_REASON)
    end

    it "is not keyed on the exit code (ssh's 255 would classify the same way)" do
      allow(Open3).to receive(:capture3) do |*args, **_kwargs|
        argv = (args.first.is_a?(Hash) ? args[1..] : args).map(&:to_s)
        invocations << { env: args.first.is_a?(Hash) ? args.first : {}, argv: argv }
        [ git_response[0], git_response[1], instance_double(Process::Status, success?: false, exitstatus: 255) ]
      end

      expect(described_class.sync!(repository).reason).to eq(described_class::HOST_KEY_MISMATCH_REASON)
    end

    # A different failure that merely mentions the text (a hook on the
    # remote printing it, say) is not a mismatch about THIS host.
    it "does not report a mismatch when the alias is absent from stderr" do
      allow(Open3).to receive(:capture3) do |*args, **_kwargs|
        argv = (args.first.is_a?(Hash) ? args[1..] : args).map(&:to_s)
        invocations << { env: args.first.is_a?(Hash) ? args.first : {}, argv: argv }
        [ "", "Host key verification failed.\n", instance_double(Process::Status, success?: false, exitstatus: 128) ]
      end

      result = described_class.sync!(repository)

      expect(result.ok?).to be(false)
      expect(result.reason).to be_nil
      expect(System::FleetEvent.where(kind: System::Gitops::RepositoryHostKey::MISMATCH_EVENT_KIND)).to be_empty
    end
  end

  describe "a repository with NO recorded key (trust on first use)" do
    let(:keyscan_stdout) { "[git.example.test]:2222 #{entry['type']} #{entry['key']}\n" }

    it "scans the URL's host and port, records the key as tofu, and syncs verified" do
      expect(described_class.sync!(repository).ok?).to be(true)

      expect(keyscan_invocations.map { |inv| inv[:argv] })
        .to eq([ [ "ssh-keyscan", "-T", System::Gitops::RepositoryHostKey::KEYSCAN_TIMEOUT_SECONDS.to_s,
                   "-p", "2222", "git.example.test" ] ])
      recorded = System::Gitops::RepositoryHostKey.recorded_for(repository.reload)
      expect(recorded.map { |e| e["fingerprint"] }).to eq([ fingerprint ])
      expect(repository.ssh_host_keys["source"]).to eq("tofu")

      argv = ssh_argv(git_invocations.first)
      expect(argv).to include("StrictHostKeyChecking=yes", "HostKeyAlias=#{host_alias}")
      expect(known_hosts_seen[:content]).to eq(System::SshHostKeys.known_hosts(host_alias, recorded))
    end

    it "emits the recorded event naming the source and fingerprints" do
      described_class.sync!(repository)

      event = System::FleetEvent.find_by(kind: System::Gitops::RepositoryHostKey::RECORDED_EVENT_KIND,
                                         account_id: account.id)
      expect(event).to be_present
      expect(event.severity).to eq("low")
      expect(event.payload).to include("repository_id" => repository.id, "source" => "tofu",
                                       "host" => "git.example.test", "port" => 2222,
                                       "fingerprints" => [ fingerprint ])
    end

    it "scans once: the second sync reuses the recorded key" do
      described_class.sync!(repository)
      described_class.sync!(repository)

      expect(keyscan_invocations.size).to eq(1)
    end

    context "when the scan yields nothing" do
      let(:keyscan_stdout) { "" }

      it "refuses the sync with a named reason and never runs git unverified" do
        result = described_class.sync!(repository)

        expect(result.ok?).to be(false)
        expect(result.reason).to eq(described_class::HOST_KEY_UNAVAILABLE_REASON)
        expect(git_invocations).to be_empty
        expect(repository.reload.ssh_host_keys).to be_nil
      end
    end
  end

  describe "an https remote" do
    let(:vault_payload) { { username: "deploy-bot", password: "pat-#{SecureRandom.hex(4)}" } }
    let(:repository) do
      create(:system_gitops_repository, account: account,
                                        repo_url: "https://git.example.test/powernode/fleet-config.git",
                                        vault_credential_path: vault_path)
    end

    it "is untouched: no keyscan, no GIT_SSH_COMMAND, no recorded key" do
      expect(described_class.sync!(repository).ok?).to be(true)

      expect(keyscan_invocations).to be_empty
      expect(git_invocations.first[:env]).not_to have_key("GIT_SSH_COMMAND")
      expect(git_invocations.first[:env]["GIT_ASKPASS"]).to be_present
      expect(repository.reload.ssh_host_keys).to be_nil
    end
  end

  describe "an ssh remote with no credential path" do
    let(:repository) do
      create(:system_gitops_repository, account: account,
                                        repo_url: "git@git.example.test:powernode/fleet-config.git",
                                        vault_credential_path: nil)
    end

    before { record_key! }

    it "still verifies the host (strict options, no -i)" do
      expect(described_class.sync!(repository).ok?).to be(true)

      argv = ssh_argv(git_invocations.first)
      expect(argv).to include("StrictHostKeyChecking=yes", "HostKeyAlias=#{host_alias}")
      expect(argv).not_to include("-i")
    end
  end
end
