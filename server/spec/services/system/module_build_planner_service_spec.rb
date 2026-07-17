# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc9 (Part A) — System::ModuleBuildPlannerService.
#
# The parity tests below mirror scripts/test-ci-compute-dirty-closure.sh's
# fixture graph and test cases EXACTLY (same 6-module graph, same expected
# closures) so this Ruby port can't silently drift from the bash script it
# replaces for server-side (checkout-less) planning. Apt-closure drift
# probing is explicitly out of scope (deferred to inc12) — this only covers
# the bash script's TRIGGER-PATH logic (source-path filter + catch-alls +
# reverse-dependency expansion).
RSpec.describe System::ModuleBuildPlannerService do
  let!(:account) { create(:account) }
  let(:gitea_provider) { create(:git_provider, :gitea, account: account) }
  let!(:gitea_credential) do
    create(:git_provider_credential, :gitea, account: account, provider: gitea_provider)
  end

  # Mirrors scripts/test-ci-compute-dirty-closure.sh's make_fixture_repo graph:
  #
  #   base-os (provides base.os)
  #     |-- postgres-primary (requires base-os; provides database.postgres)
  #     |     `-- postgres-replica (requires base-os, postgres-primary)
  #     |-- redis (requires base-os; provides cache.redis)
  #     `-- hub-backend (requires base-os, postgres-primary, redis)
  #   powernode-system-base (standalone; the agent/** special-case target)
  #
  # The bash fixture resolves requires via capability tags; here the graph
  # is expressed directly as the already-resolved System::ModuleDependency
  # rows ManifestImportService would have produced — the planner consumes
  # that resolved graph, not raw manifest YAML, so this is the correct
  # fixture shape for it.
  let!(:base_os)     { create(:system_node_module, account: account, name: "base-os", manifest_yaml: "schema_version: 1") }
  let!(:pg_primary)  { create(:system_node_module, account: account, name: "postgres-primary", manifest_yaml: "schema_version: 1") }
  let!(:pg_replica)  { create(:system_node_module, account: account, name: "postgres-replica", manifest_yaml: "schema_version: 1") }
  let!(:redis)       { create(:system_node_module, account: account, name: "redis", manifest_yaml: "schema_version: 1") }
  let!(:hub_backend) { create(:system_node_module, account: account, name: "hub-backend", manifest_yaml: "schema_version: 1") }
  let!(:system_base) { create(:system_node_module, account: account, name: "powernode-system-base", manifest_yaml: "schema_version: 1") }

  let!(:dep_pg_primary_base) { create(:system_module_dependency, node_module: pg_primary, dependency: base_os) }
  let!(:dep_pg_replica_base) { create(:system_module_dependency, node_module: pg_replica, dependency: base_os) }
  let!(:dep_pg_replica_pg)   { create(:system_module_dependency, node_module: pg_replica, dependency: pg_primary) }
  let!(:dep_redis_base)      { create(:system_module_dependency, node_module: redis, dependency: base_os) }
  let!(:dep_hub_base)        { create(:system_module_dependency, node_module: hub_backend, dependency: base_os) }
  let!(:dep_hub_pg)          { create(:system_module_dependency, node_module: hub_backend, dependency: pg_primary) }
  let!(:dep_hub_redis)       { create(:system_module_dependency, node_module: hub_backend, dependency: redis) }

  let(:base_sha) { "a" * 40 }
  let(:head_sha) { "b" * 40 }
  let(:all_module_names) { %w[base-os hub-backend postgres-primary postgres-replica powernode-system-base redis] }

  # Stubs a single synthetic commit (head_sha) touching the given paths —
  # mirrors the bash fixture's "one commit, N changed paths" shape. The changed
  # files ride on the compare response itself now (the planner reads
  # comparison[:files] directly; the old per-commit get_commit_diff walk was a
  # workaround for the core client discarding that field).
  def stub_changed_paths(paths, source_repo: "powernode/powernode-system")
    owner, repo = source_repo.split("/", 2)
    fake_client = instance_double(Devops::Git::GiteaApiClient)
    allow(Devops::Git::ApiClient).to receive(:for).with(gitea_credential).and_return(fake_client)
    allow(fake_client).to receive(:compare_commits)
      .with(owner, repo, base_sha, head_sha)
      .and_return(commits: [ { sha: head_sha } ], files: paths.map { |p| { filename: p } })
    fake_client
  end

  def stub_no_changes
    fake_client = instance_double(Devops::Git::GiteaApiClient)
    allow(Devops::Git::ApiClient).to receive(:for).with(gitea_credential).and_return(fake_client)
    allow(fake_client).to receive(:compare_commits)
      .with("powernode", "powernode-system", base_sha, head_sha)
      .and_return(commits: [])
    fake_client
  end

  def modules_in(plan)
    plan.map { |p| p[:module] }.sort
  end

  it "single-module change fans out via the capability graph (bash: test_single_module_change)" do
    stub_changed_paths([ "modules/redis/rootfs/marker" ])
    plan = described_class.plan(base_sha: base_sha, head_sha: head_sha)
    expect(modules_in(plan)).to eq(%w[hub-backend redis])
  end

  it "source change pulls in dependents (bash: test_source_change_with_dependents)" do
    stub_changed_paths([ "modules/postgres-primary/rootfs/marker" ])
    plan = described_class.plan(base_sha: base_sha, head_sha: head_sha)
    expect(modules_in(plan)).to eq(%w[hub-backend postgres-primary postgres-replica])
  end

  it "agent/** change forces only powernode-system-base (bash: test_agent_change_forces_system_base)" do
    stub_changed_paths([ "agent/main.go" ])
    plan = described_class.plan(base_sha: base_sha, head_sha: head_sha)
    expect(modules_in(plan)).to eq(%w[powernode-system-base])
  end

  it "workflow catch-all forces every module (bash: test_workflow_change_forces_all)" do
    stub_changed_paths([ ".gitea/workflows/build-platform-modules.yaml" ])
    plan = described_class.plan(base_sha: base_sha, head_sha: head_sha)
    expect(modules_in(plan)).to eq(all_module_names.sort)
  end

  it "Containerfile catch-all also forces every module" do
    stub_changed_paths([ "templates/module-repo/Containerfile" ])
    plan = described_class.plan(base_sha: base_sha, head_sha: head_sha)
    expect(modules_in(plan)).to eq(all_module_names.sort)
  end

  it "no changes -> empty plan (bash: test_no_changes)" do
    stub_no_changes
    plan = described_class.plan(base_sha: base_sha, head_sha: head_sha)
    expect(plan).to eq([])
  end

  it "manifest-only change still fans out (bash: test_manifest_only_change_still_dirty)" do
    stub_changed_paths([ "modules/redis/manifest.yaml" ])
    plan = described_class.plan(base_sha: base_sha, head_sha: head_sha)
    expect(modules_in(plan)).to eq(%w[hub-backend redis])
  end

  it "diamond dependency: base-os change pulls in all 4 dependents (bash: test_diamond_dependency)" do
    stub_changed_paths([ "modules/base-os/rootfs/marker" ])
    plan = described_class.plan(base_sha: base_sha, head_sha: head_sha)
    expect(modules_in(plan)).to eq(%w[base-os hub-backend postgres-primary postgres-replica redis])
  end

  it "a changed path under an unknown module directory is ignored" do
    stub_changed_paths([ "modules/totally-unregistered-mod/rootfs/marker" ])
    plan = described_class.plan(base_sha: base_sha, head_sha: head_sha)
    expect(plan).to eq([])
  end

  describe "force_all: true" do
    it "returns every module with a manifest without ever consulting the Gitea API" do
      expect(Devops::Git::ApiClient).not_to receive(:for)
      plan = described_class.plan(base_sha: base_sha, head_sha: head_sha, force_all: true)
      expect(modules_in(plan)).to eq(all_module_names.sort)
    end

    it "excludes a NodeModule with no manifest_yaml even under force_all" do
      create(:system_node_module, account: account, name: "no-manifest-yet", manifest_yaml: nil)
      plan = described_class.plan(base_sha: base_sha, head_sha: head_sha, force_all: true)
      expect(modules_in(plan)).not_to include("no-manifest-yet")
    end
  end

  describe "oci_ref" do
    it "is the first 7 characters of head_sha for every planned module" do
      stub_changed_paths([ "modules/redis/rootfs/marker" ])
      plan = described_class.plan(base_sha: base_sha, head_sha: head_sha)
      expect(plan).to all(include(oci_ref: head_sha[0, 7]))
    end
  end

  describe "repo-aware source (imp 019f71e2)" do
    it "diffs the caller-specified source_repo instead of the default manifest repo" do
      # The stub only answers for powernode-platform; a call against the default
      # manifest repo (powernode-system) would not match and raise, so this test
      # fails unless the source_repo is actually threaded through to the compare.
      stub_changed_paths([ "modules/redis/rootfs/marker" ], source_repo: "powernode/powernode-platform")
      plan = described_class.plan(base_sha: base_sha, head_sha: head_sha, source_repo: "powernode/powernode-platform")
      expect(modules_in(plan)).to eq(%w[hub-backend redis])
    end

    it "falls back to the default manifest repo when source_repo is nil" do
      fake = stub_changed_paths([ "modules/redis/rootfs/marker" ])
      described_class.plan(base_sha: base_sha, head_sha: head_sha)
      expect(fake).to have_received(:compare_commits).with("powernode", "powernode-system", base_sha, head_sha)
    end
  end

  describe "planning failures surface, rather than silently returning an empty plan" do
    it "raises PlanningError when the account has no active Gitea credential" do
      gitea_credential.update!(is_active: false)

      expect {
        described_class.plan(base_sha: base_sha, head_sha: head_sha)
      }.to raise_error(System::ModuleBuildPlannerService::PlanningError, /credential/)
    end

    it "raises PlanningError when the Gitea compare call fails" do
      fake_client = instance_double(Devops::Git::GiteaApiClient)
      allow(Devops::Git::ApiClient).to receive(:for).and_return(fake_client)
      allow(fake_client).to receive(:compare_commits)
        .and_raise(Devops::Git::ApiClient::ServerError.new("boom", 500))

      expect {
        described_class.plan(base_sha: base_sha, head_sha: head_sha)
      }.to raise_error(System::ModuleBuildPlannerService::PlanningError, /Gitea compare/)
    end

    # HARD-FAIL guard: a real commit range that returns zero changed files is the
    # silent-diff-failure signature the whole increment exists to catch — the
    # batch must fail loudly instead of "succeeding" having built nothing.
    it "raises PlanningError when a real commit range yields zero changed files" do
      fake_client = instance_double(Devops::Git::GiteaApiClient)
      allow(Devops::Git::ApiClient).to receive(:for).with(gitea_credential).and_return(fake_client)
      allow(fake_client).to receive(:compare_commits)
        .with("powernode", "powernode-system", base_sha, head_sha)
        .and_return(commits: [ { sha: head_sha } ], files: [])

      expect {
        described_class.plan(base_sha: base_sha, head_sha: head_sha)
      }.to raise_error(System::ModuleBuildPlannerService::PlanningError, /zero changed files/)
    end
  end
end
