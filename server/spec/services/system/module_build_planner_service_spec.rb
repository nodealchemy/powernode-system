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

  # Stubs a single synthetic commit (head_sha) touching the given paths. Mirrors
  # the REAL live Gitea shape (confirmed by probe): the compare API returns only
  # {commits,total_commits} — NO files array — so the planner enumerates the
  # commits and reads each commit's own changed files via #get_commit.
  def stub_changed_paths(paths, source_repo: "powernode/powernode-system")
    owner, repo = source_repo.split("/", 2)
    fake_client = instance_double(Devops::Git::GiteaApiClient)
    allow(Devops::Git::ApiClient).to receive(:for).with(gitea_credential).and_return(fake_client)
    allow(fake_client).to receive(:compare_commits)
      .with(owner, repo, base_sha, head_sha)
      .and_return(commits: [ { sha: head_sha } ])
    allow(fake_client).to receive(:get_commit)
      .with(owner, repo, head_sha)
      .and_return(files: paths.map { |p| { filename: p } })
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

  # Was "a changed path under an unknown module directory is ignored" (plan ==
  # []). Silently ignoring it is the shipped-a-build-that-built-nothing bug
  # (imp b9e3e05a5119): the diff DID name a module directory, so the request
  # was not a no-op — it resolved to nothing, which is a failure. Not a
  # bash-parity case (the bash script derives its module list from the repo's
  # own modules/ tree, so an unregistered dir cannot occur there; here the
  # list comes from the DB, so this is a repo/DB divergence).
  it "hard-fails when a changed path names an unknown module directory and nothing else" do
    stub_changed_paths([ "modules/totally-unregistered-mod/rootfs/marker" ])
    expect {
      described_class.plan(base_sha: base_sha, head_sha: head_sha)
    }.to raise_error(described_class::PlanningError, /totally-unregistered-mod \(unknown_module\)/)
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

  # A CORE (powernode-platform) change never planned anything: the only path
  # rules were modules/<slug>/ and agent/, so server/** matched nothing and the
  # planner returned an EMPTY plan with no error — the empty-plan guard stays
  # silent when zero candidates were named. Two live dispatches planned 0 modules
  # before this was found.
  describe "core-repo path mapping" do
    let!(:hub_backend_real) do
      create(:system_node_module, account: account, name: "powernode-hub-backend",
             manifest_yaml: "schema_version: 1")
    end
    let!(:hub_worker_real) do
      create(:system_node_module, account: account, name: "powernode-hub-worker",
             manifest_yaml: "schema_version: 1")
    end
    let!(:ext_system_real) do
      create(:system_node_module, account: account, name: "powernode-extension-system",
             manifest_yaml: "schema_version: 1")
    end

    def core_plan(paths)
      stub_changed_paths(paths, source_repo: "powernode/powernode-platform")
      described_class.plan(base_sha: base_sha, head_sha: head_sha,
                           source_repo: "powernode/powernode-platform")
    end

    it "plans hub-backend for a core server/ change" do
      expect(modules_in(core_plan([ "server/app/services/ai/ralph/test_verification_service.rb" ])))
        .to include("powernode-hub-backend")
    end

    it "plans hub-worker for a core worker/ change" do
      expect(modules_in(core_plan([ "worker/app/jobs/some_job.rb" ])))
        .to include("powernode-hub-worker")
    end

    it "plans the extension module for a core extensions/system pointer bump" do
      expect(modules_in(core_plan([ "extensions/system" ])))
        .to include("powernode-extension-system")
    end

    it "plans hub-backend ONCE for several core server/ files" do
      plan = core_plan([ "server/app/models/a.rb", "server/app/models/b.rb", "server/config/routes.rb" ])
      expect(modules_in(plan).count("powernode-hub-backend")).to eq(1)
    end

    it "plans hub-backend for the other trees it packages (scripts/, loader helper)" do
      # hub-backend's file_spec is server/** + scripts/** + extensions_loader_helper.rb.
      expect(modules_in(core_plan([ "scripts/pattern-validation.sh" ])))
        .to include("powernode-hub-backend")
      expect(modules_in(core_plan([ "extensions_loader_helper.rb" ])))
        .to include("powernode-hub-backend")
    end

    # THE SILENT-ZERO DEFECT. Two hard-fail guards already cover an empty diff
    # and a failed compare, so the only way to "successfully" build nothing is a
    # compare that returns files none of which match a rule: candidates is empty,
    # so guard_against_empty_plan!'s `catch_all || candidates.any?` returns early.
    # For a CORE range that means a MISSING RULE, and it must be loud.
    describe "a core range that maps to nothing" do
      it "raises instead of silently planning 0 modules" do
        expect { core_plan([ "configs/vault/policy.hcl" ]) }
          .to raise_error(described_class::PlanningError, /no core path rule/i)
      end

      it "names the unmapped paths so the missing rule is obvious" do
        expect { core_plan([ "configs/vault/policy.hcl", "Makefile" ]) }
          .to raise_error(described_class::PlanningError, /configs\/vault\/policy\.hcl.*Makefile/m)
      end

      it "points at the core repo it diffed, so a wrong source_repo is visible" do
        expect { core_plan([ "configs/vault/policy.hcl" ]) }
          .to raise_error(described_class::PlanningError, %r{powernode/powernode-platform})
      end

      # Docs and repo hygiene ship in no module. A core push touching only those
      # genuinely has nothing to build — that must stay a quiet no-op, or every
      # docs/reference/auto regeneration becomes a failed dispatch.
      it "stays a silent no-op for a docs-only core push" do
        expect(modules_in(core_plan([ "docs/operations/runbook.md" ]))).to be_empty
      end

      it "stays a silent no-op for root markdown and CI config" do
        expect(modules_in(core_plan([ "README.md", ".github/workflows/ci.yml" ]))).to be_empty
      end

      # An unmapped path riding along with a mapped one is NOT the silent-zero
      # bug — something is built and the caller is told what. Out of scope here.
      it "does not raise when an unmapped path accompanies a mapped one" do
        expect(modules_in(core_plan([ "configs/vault/policy.hcl", "server/app/models/a.rb" ])))
          .to include("powernode-hub-backend")
      end

      # The manifest repo has its own legitimate zero-plan cases (a docs-only or
      # server/** push there). Widening the guard must not change that.
      it "leaves a manifest-repo zero-plan silent, exactly as before" do
        stub_changed_paths([ "server/app/services/system/whatever.rb" ])
        expect(modules_in(described_class.plan(base_sha: base_sha, head_sha: head_sha))).to be_empty
      end
    end

    # `server/` exists in BOTH repos and means different things — core's Rails app
    # vs the extension's. The core rules must NOT leak into a manifest-repo diff.
    it "does not apply core rules when diffing the manifest repo" do
      stub_changed_paths([ "server/app/services/system/whatever.rb" ])
      plan = described_class.plan(base_sha: base_sha, head_sha: head_sha)

      expect(modules_in(plan)).not_to include("powernode-hub-backend")
    end
  end

  describe "repo-aware source (imp 019f71e2)" do
    it "diffs the caller-specified source_repo instead of the default manifest repo" do
      # The stub only answers for this repo; a call against the default manifest
      # repo (powernode-system) would not match and raise, so this test fails
      # unless the source_repo is actually threaded through to the compare.
      #
      # Uses a manifest-SHAPED fork rather than powernode-platform: this asserts
      # threading via a modules/<slug>/ path, and the core repo has no modules/
      # tree at all — feeding it a modules/ path exercised a combination that
      # cannot occur, and now correctly plans nothing under the core rules.
      # Core-repo path mapping has its own describe block above.
      stub_changed_paths([ "modules/redis/rootfs/marker" ], source_repo: "powernode/powernode-system-fork")
      plan = described_class.plan(base_sha: base_sha, head_sha: head_sha,
                                  source_repo: "powernode/powernode-system-fork")
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

    # HARD-FAIL guard: a real commit range that returns zero changed files (via
    # both the compare list AND the per-commit walk) is the silent-diff-failure
    # signature the whole increment exists to catch — the batch must fail loudly
    # instead of "succeeding" having built nothing.
    it "raises PlanningError when a real commit range yields zero changed files" do
      fake_client = instance_double(Devops::Git::GiteaApiClient)
      allow(Devops::Git::ApiClient).to receive(:for).with(gitea_credential).and_return(fake_client)
      allow(fake_client).to receive(:compare_commits)
        .with("powernode", "powernode-system", base_sha, head_sha)
        .and_return(commits: [ { sha: head_sha } ])
      allow(fake_client).to receive(:get_commit)
        .with("powernode", "powernode-system", head_sha)
        .and_return(files: [])

      expect {
        described_class.plan(base_sha: base_sha, head_sha: head_sha)
      }.to raise_error(System::ModuleBuildPlannerService::PlanningError, /zero changed files/)
    end
  end

  # === imp b9e3e05a5119 — the planner must EXPLAIN what it dropped ===
  #
  # A module materialized by System::PackageModuleMaterializer has a blank
  # manifest_yaml and no modules/<slug>/ tree, so it is invisible to both the
  # diff (nothing can make it dirty) and #known_module_names (the manifest
  # filter). That exclusion is CORRECT — package modules build through
  # System::PackageClosureBuildBridge's own `package`-trigger batch — but it
  # was silent, so `force_all` reported a successful plan while quietly
  # skipping every package-origin module.
  describe "excluded modules carry a reason (imp b9e3e05a5119)" do
    let!(:pkg_link) { create(:system_package_module_link, node_module: pkg_module, package_name: "python3") }
    let!(:pkg_module) { create(:system_node_module, account: account, name: "python3", manifest_yaml: nil) }

    it "keeps .plan returning the bare entries array (unchanged contract for existing callers)" do
      plan = described_class.plan(base_sha: base_sha, head_sha: head_sha, force_all: true)
      expect(plan).to be_an(Array)
      expect(modules_in(plan)).to eq(all_module_names.sort)
    end

    it "surfaces a package-origin module as excluded-with-reason under force_all" do
      result = described_class.plan_with_diagnostics(base_sha: base_sha, head_sha: head_sha, force_all: true)

      expect(result.entries.map { |e| e[:module] }).not_to include("python3")
      excluded = result.excluded.find { |e| e[:module] == "python3" }
      expect(excluded).to be_present
      expect(excluded[:reason]).to eq("package_origin")
      expect(excluded[:detail]).to include("system_refresh_package_module")
      # The remedy action keys off the link, not the module — carry its id so
      # acting on the exclusion needs no second lookup.
      expect(excluded[:package_module_link_id]).to eq(pkg_link.id)
    end

    it "distinguishes a manifest-less operator-authored module from a package-origin one" do
      create(:system_node_module, account: account, name: "not-yet-imported", manifest_yaml: nil)

      result = described_class.plan_with_diagnostics(base_sha: base_sha, head_sha: head_sha, force_all: true)

      expect(result.excluded.find { |e| e[:module] == "not-yet-imported" }[:reason]).to eq("no_manifest")
    end

    it "reports a dirty slug that names no NodeModule at all, without failing a plan that still has work" do
      stub_changed_paths([ "modules/redis/rootfs/marker", "modules/ghost-mod/rootfs/marker" ])

      result = described_class.plan_with_diagnostics(base_sha: base_sha, head_sha: head_sha)

      expect(result.entries.map { |e| e[:module] }.sort).to eq(%w[hub-backend redis])
      expect(result.excluded.map { |e| [ e[:module], e[:reason] ] }).to eq([ [ "ghost-mod", "unknown_module" ] ])
    end

    it "excludes nothing when every dirty slug maps to a buildable module" do
      stub_changed_paths([ "modules/redis/rootfs/marker" ])

      expect(described_class.plan_with_diagnostics(base_sha: base_sha, head_sha: head_sha).excluded).to eq([])
    end
  end

  # A plan of 0 modules for a change set that DID name modules is the
  # "successful build that built nothing" signature — the orchestrator's
  # #finish_empty_batch! walks a 0-module batch straight through AASM to
  # `complete`, so nothing downstream can catch it. Fail at the planner, which
  # is the one layer that still knows what was asked for.
  describe "a request that resolves to 0 modules hard-fails (imp b9e3e05a5119)" do
    it "raises naming the diff size when every dirty slug from a non-empty diff is unbuildable" do
      stub_changed_paths([ "modules/ghost-mod/rootfs/marker", "modules/other-ghost/manifest.yaml" ])

      expect {
        described_class.plan(base_sha: base_sha, head_sha: head_sha)
      }.to raise_error(described_class::PlanningError, /2 changed file\(s\)/)
    end

    it "names each unbuildable slug and its reason in the error" do
      stub_changed_paths([ "modules/ghost-mod/rootfs/marker" ])

      expect {
        described_class.plan(base_sha: base_sha, head_sha: head_sha)
      }.to raise_error(described_class::PlanningError, /ghost-mod \(unknown_module\)/)
    end

    it "raises under force_all when no module in the account has an imported manifest" do
      System::NodeModule.where(account: account).update_all(manifest_yaml: nil)
      create(:system_package_module_link, node_module: redis, package_name: "redis")

      expect {
        described_class.plan(base_sha: base_sha, head_sha: head_sha, force_all: true)
      }.to raise_error(described_class::PlanningError, /package_origin/)
    end

    # The legitimate no-op the guard must NOT swallow: a real change set that
    # touches no module trigger path at all (docs, README) genuinely needs no
    # module rebuild. Only a change set that NAMED modules and resolved to
    # none is a failure.
    it "still allows a non-empty diff that touches no module trigger path" do
      stub_changed_paths([ "docs/README.md", "CHANGELOG.md" ])

      expect(described_class.plan(base_sha: base_sha, head_sha: head_sha)).to eq([])
    end

    # DECIDED behavior, pinned: retiring a module (NodeModule deleted, then
    # its modules/<slug>/ tree removed) makes the deletion push resolve to 0
    # modules, and that now hard-fails where it used to pass silently. The
    # failure is correct — the push has nothing to build — so the message has
    # to say which case the reader is in.
    it "hard-fails a pure module-deletion push and names the retirement case" do
      stub_changed_paths([ "modules/old-mod/manifest.yaml", "modules/old-mod/rootfs/marker" ])

      expect {
        described_class.plan(base_sha: base_sha, head_sha: head_sha)
      }.to raise_error(described_class::PlanningError, /deliberately retired.*system_delete_module/m)
    end

    # The same deletion riding along with real work must NOT fail the batch —
    # the guard only fires when the WHOLE plan resolves to nothing.
    it "does not fail a deletion push that also touches a live module" do
      stub_changed_paths([ "modules/old-mod/manifest.yaml", "modules/redis/rootfs/marker" ])

      result = described_class.plan_with_diagnostics(base_sha: base_sha, head_sha: head_sha)

      expect(result.entries.map { |e| e[:module] }.sort).to eq(%w[hub-backend redis])
      expect(result.excluded.map { |e| e[:module] }).to eq([ "old-mod" ])
    end

    # DECIDED behavior, pinned: a fresh account still raises under force_all,
    # but "0 of 0 module(s) have an imported manifest_yaml" reads as a bug in
    # the planner. An empty catalog is a diagnosis — say that.
    it "diagnoses an empty catalog instead of reporting a 0-of-0 manifest ratio" do
      # Every account is bootstrapped with a handful of modules
      # (System::AccountBootstrapService), so an empty catalog has to be made.
      # current_version_id is nulled first: node_modules and
      # node_module_versions reference each other, so destroy_all alone
      # deadlocks on the circular FK.
      System::NodeModule.where(account: account).update_all(current_version_id: nil)
      System::NodeModule.where(account: account).destroy_all

      expect {
        described_class.plan(base_sha: base_sha, head_sha: head_sha, force_all: true)
      }.to raise_error(described_class::PlanningError) { |e|
        expect(e.message).to include("no modules exist in this account")
        expect(e.message).not_to match(/of 0 module/)
      }
    end

    # An all-package-origin account would otherwise render every module name
    # into an error string that lands in webhook bodies and logs. Asserted on
    # the cap rather than a hardcoded overflow count — the spec DB carries a
    # handful of pre-seeded manifest-less modules, so the total is not just
    # what this example creates.
    it "caps the excluded list named in the error and summarizes the overflow" do
      System::NodeModule.where(account: account).update_all(manifest_yaml: nil)
      30.times { |i| create(:system_node_module, account: account, name: "pkg-#{i}", manifest_yaml: nil) }

      expect {
        described_class.plan(base_sha: base_sha, head_sha: head_sha, force_all: true)
      }.to raise_error(described_class::PlanningError) { |e|
        expect(e.message.scan(/\(no_manifest\)/).size).to eq(described_class::EXCLUDED_MESSAGE_SAMPLE_LIMIT)
        expect(e.message).to match(/\+\d+ more/)
        expect(e.message.length).to be < 2_000
      }
    end
  end

  describe "compare-files forward-compat fast path (imp 019f71e3)" do
    # Today's Gitea omits a top-level files[] on compare; if a future version
    # adds it, the planner uses it directly and skips the per-commit walk.
    it "derives changed paths from the compare response's files when present, without walking commits" do
      fake_client = instance_double(Devops::Git::GiteaApiClient)
      allow(Devops::Git::ApiClient).to receive(:for).with(gitea_credential).and_return(fake_client)
      allow(fake_client).to receive(:compare_commits)
        .with("powernode", "powernode-system", base_sha, head_sha)
        .and_return(commits: [ { sha: head_sha } ], files: [ { filename: "modules/redis/rootfs/marker" } ])
      expect(fake_client).not_to receive(:get_commit)

      plan = described_class.plan(base_sha: base_sha, head_sha: head_sha)
      expect(modules_in(plan)).to eq(%w[hub-backend redis])
    end
  end
end
