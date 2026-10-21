# frozen_string_literal: true

require "rails_helper"

# IMP adversarial review r2 #15 — a SIGKILL between the key write and its
# cleanup left a 0600 private key in gitops-secrets-* under the work-tree root.
# sync! sweeps stale ones first.
RSpec.describe System::Gitops::RepoSyncService, "stale secret directories" do
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
end
