# frozen_string_literal: true

require "rails_helper"

# IMP adversarial review r2 #15 — a SIGKILL between the key write and its
# cleanup left a 0600 private key in gitops-secrets-* under the work-tree root.
# sync! sweeps stale ones first.
RSpec.describe System::Gitops::RepoSyncService, "stale secret directories" do
  include ProcessLivenessHelpers

  let(:account) { create(:account) }
  let(:root) { Pathname.new(Dir.mktmpdir("gitops-root-")) }
  let(:repository) do
    instance_double(System::GitopsRepository, id: SecureRandom.uuid, account_id: account.id,
                    repo_url: "https://example.invalid/r.git", branch: "main", vault_credential_path: nil)
  end

  before do
    stub_const("System::Gitops::RepoSyncService::WORK_TREE_ROOT", root)
    allow_any_instance_of(described_class).to receive(:fast_forward)
    allow_any_instance_of(described_class).to receive(:clone_fresh)
    allow_any_instance_of(described_class).to receive(:read_commit_sha).and_return("abc")
  end

  after { FileUtils.rm_rf(root) }

  def leftover(account_dir, age:)
    dir = root.join(account_dir, "gitops-secrets-#{SecureRandom.hex(3)}")
    FileUtils.mkdir_p(dir)
    File.write(dir.join("key"), "FAKE-KEY-MATERIAL", perm: 0o600)
    File.utime(Time.now - age, Time.now - age, dir)
    dir
  end

  it "removes a stale secrets dir left by a killed sync, anywhere under the root" do
    stale = leftover("some-other-account", age: 2 * 3600)

    described_class.sync!(repository)

    expect(stale).not_to exist
  end

  it "leaves a fresh secrets dir alone (a concurrent sync may be using it)" do
    fresh = leftover(account.id.to_s, age: 10)

    described_class.sync!(repository)

    expect(fresh).to exist
  end

  it "does not fail the sync when a sweep entry cannot be removed" do
    leftover("acct", age: 2 * 3600)
    allow(FileUtils).to receive(:rm_rf).and_call_original
    allow(FileUtils).to receive(:rm_rf).with(a_string_matching(/gitops-secrets-/)).and_raise(Errno::EACCES)

    expect(described_class.sync!(repository)).to be_ok
  end

  describe "the git timeout" do
    subject(:service) { described_class.new(repository) }

    it "kills a git exec that outlives CLONE_TIMEOUT_SEC and raises a timeout error" do
      stub_const("System::Gitops::RepoSyncService::CLONE_TIMEOUT_SEC", 1)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { service.send(:capture_git, "sleep", "30", chdir: Dir.tmpdir) }
        .to raise_error(described_class::GitTimeoutError)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
    end

    it "kills the whole process group: a grandchild of the timed-out exec does not survive" do
      stub_const("System::Gitops::RepoSyncService::CLONE_TIMEOUT_SEC", 1)
      pidfile = File.join(Dir.mktmpdir("pg-"), "child.pid")
      grandchild = nil

      begin
        expect { service.send(:capture_git, "sh", "-c", "sleep 300 & echo $! > #{pidfile}; wait", chdir: Dir.tmpdir) }
          .to raise_error(described_class::GitTimeoutError)
        grandchild = File.read(pidfile).to_i
        expect(grandchild).to be > 1

        gone = 20.times.any? do
          sleep 0.1
          process_dead?(grandchild)
        end
        expect(gone).to be(true), "the sleep started under the timed-out exec is still running (pid #{grandchild})"
      ensure
        Process.kill("KILL", grandchild) if grandchild.to_i > 1 && !process_dead?(grandchild)
      end
    end

    it "does not print a thread exception when it kills the exec" do
      stub_const("System::Gitops::RepoSyncService::CLONE_TIMEOUT_SEC", 1)

      expect { service.send(:capture_git, "sleep", "30", chdir: Dir.tmpdir) rescue nil }
        .not_to output(/terminated with exception/).to_stderr
    end

    it "still returns output, error and status for a git exec inside the limit" do
      out, _err, status = service.send(:capture_git, "echo", "hi", chdir: Dir.tmpdir)

      expect(out.strip).to eq("hi")
      expect(status).to be_success
    end

    describe "kill_git and a reaped exec" do
      # A reaped pid's group id can be reused by an unrelated process group,
      # so a signal is sent only while the exec is still alive.
      let(:wait_thr) { instance_double(Process::Waiter, pid: 4_000_001) }

      it "sends no signal when the exec has already exited" do
        allow(wait_thr).to receive(:alive?).and_return(false)
        allow(wait_thr).to receive(:join).and_return(wait_thr)
        expect(Process).not_to receive(:kill)

        service.send(:kill_git, wait_thr)
      end

      it "sends no KILL when the exec exited after TERM, even if the join timed out" do
        allow(wait_thr).to receive(:alive?).and_return(true, false)
        allow(wait_thr).to receive(:join).and_return(nil)
        expect(Process).to receive(:kill).with("TERM", -4_000_001).once
        expect(Process).not_to receive(:kill).with("KILL", anything)

        service.send(:kill_git, wait_thr)
      end

      it "still escalates to KILL when the exec survives TERM" do
        allow(wait_thr).to receive(:alive?).and_return(true)
        allow(wait_thr).to receive(:join).and_return(nil)
        expect(Process).to receive(:kill).with("TERM", -4_000_001).ordered
        expect(Process).to receive(:kill).with("KILL", -4_000_001).ordered

        service.send(:kill_git, wait_thr)
      end
    end

    it "sweeps only secrets dirs older than the git timeout plus a margin" do
      expect(described_class::STALE_SECRETS_AGE).to be > described_class::CLONE_TIMEOUT_SEC.seconds
    end
  end
end
