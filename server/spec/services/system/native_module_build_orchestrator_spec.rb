# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc9 Part B — System::NativeModuleBuildOrchestrator.
# dispatch! (lease + ci.module_build Task creation, concurrency cap) and
# advance! (sign + publish + release on success; retry-on-failure up to
# max_attempts; fail-closed when signing/publish doesn't succeed).
#
# Mirrors ci_runner_lease_service_spec.rb's seed_pool_member pattern
# (InstancePool has no factory in this suite).
RSpec.describe System::NativeModuleBuildOrchestrator do
  let(:account)         { create(:account) }
  let(:node_template)   { create(:system_node_template, account: account) }
  let(:provider_region) { create(:system_provider_region) }
  let(:instance_type)   { create(:system_provider_instance_type) }

  let(:pool) do
    System::InstancePool.create!(
      account: account,
      node_template: node_template,
      name: described_class::DEFAULT_POOL_NAME,
      target_size: 5,
      min_size: 1,
      max_size: 5,
      lifecycle_class: "ephemeral",
      status: "active",
      provider_region: provider_region,
      provider_instance_type: instance_type
    )
  end

  def seed_pool_member(state: "ready")
    pool # ensure the pool exists
    node = create(:system_node, account: account, node_template: node_template, lifecycle_class: "ephemeral")
    create(:system_node_instance,
           node: node,
           name: "member-#{SecureRandom.hex(3)}",
           variety: "cloud",
           status: state == "ready" ? "running" : "pending",
           provider_region: provider_region,
           provider_instance_type: instance_type,
           instance_pool_id: pool.id,
           pool_state: state,
           pool_warming_started_at: 1.minute.ago)
  end

  def create_module(name)
    create(:system_node_module, account: account, name: name, gitea_repo_full_name: "powernode/#{name}")
  end

  def build_batch(modules:, base_sha: "base0000", head_sha: "headsha1234567", tag: "abc1234")
    plan = modules.map { |m| { module: m.name, oci_ref: tag } }
    System::ModuleBuildBatch.create_for(account: account, plan: plan, trigger: "manual",
                                        base_sha: base_sha, head_sha: head_sha)
  end

  before do
    allow(::System::DiskImageRegistryConfig).to receive(:registry_host).and_return("registry.example.com")
    # The GitHub-mirror pre-flight reaches the network for every Class-B batch.
    # Default it to NOT MEASURED (the non-blocking state) so examples that are
    # about something else keep testing their own subject; the examples that
    # ARE about the pre-flight stub a mirror tip of their own.
    allow(::System::CoreMirrorPreflight).to receive(:resolve_mirror_tip).and_return(nil)
  end

  describe "#dispatch!" do
    it "leases a builder and creates a ci.module_build Task with the correct options per module" do
      seed_pool_member
      seed_pool_member
      mod_a = create_module("mod-a")
      mod_b = create_module("mod-b")
      batch = build_batch(modules: [ mod_a, mod_b ])

      result = described_class.dispatch!(batch: batch)

      expect(result.dispatched).to eq(2)
      expect(result.queued).to eq(0)
      expect(batch.reload.status).to eq("dispatched")

      tasks = System::Task.where(command: "ci.module_build", account: account)
      expect(tasks.count).to eq(2)

      task_a = tasks.detect { |t| t.options["module"] == "mod-a" }
      expect(task_a).to be_present
      expect(task_a.status).to eq("pending")
      expect(task_a.options["sha"]).to eq(batch.head_sha)
      expect(task_a.options["oci_ref"]).to eq("abc1234")
      expect(task_a.options["batch_id"]).to eq(batch.id)

      lease_a = System::CiRunnerLease.for_account(account).find_by(build_task_id: task_a.id)
      expect(lease_a).to be_present
      expect(lease_a.purpose).to eq("module_build")
      expect(lease_a).to be_registered # register!'d immediately, no Gitea runner needed

      modules_state = batch.reload.metadata["modules"]
      expect(modules_state["mod-a"]["state"]).to eq("dispatched")
      expect(modules_state["mod-a"]["attempts"]).to eq(1)
      expect(modules_state["mod-a"]["lease_id"]).to eq(lease_a.id)
    end

    it "respects the concurrency cap, leaving excess modules queued (not failed)" do
      SiteSetting.set("system.module_builds.max_concurrent_builders", "2", setting_type: "integer")
      3.times { seed_pool_member }
      mods = Array.new(3) { |i| create_module("mod-cap-#{i}") }
      batch = build_batch(modules: mods)

      result = described_class.dispatch!(batch: batch)

      expect(result.dispatched).to eq(2)
      expect(result.queued).to eq(1)
      expect(System::Task.where(command: "ci.module_build", account: account).count).to eq(2)

      modules_state = batch.reload.metadata["modules"]
      expect(modules_state.values.count { |m| m["state"] == "dispatched" }).to eq(2)
      expect(modules_state.values.count { |m| m["state"] == "queued" }).to eq(1)
    end

    it "leaves a module queued (never failed) when the pool has no ready member" do
      pool # zero ready members
      mod = create_module("mod-lonely")
      batch = build_batch(modules: [ mod ])

      result = described_class.dispatch!(batch: batch)

      expect(result.dispatched).to eq(0)
      expect(result.queued).to eq(1)
      expect(System::Task.where(command: "ci.module_build").count).to eq(0)
      expect(batch.reload.metadata["modules"]["mod-lonely"]["state"]).to eq("queued")
    end

    it "marks a module failed directly (no retry) when its NodeModule cannot be resolved" do
      seed_pool_member
      batch = System::ModuleBuildBatch.create_for(
        account: account, plan: [ { module: "ghost-module", oci_ref: "abc1234" } ],
        trigger: "manual", base_sha: "base0000", head_sha: "headsha1234567"
      )

      described_class.dispatch!(batch: batch)

      expect(System::Task.where(command: "ci.module_build").count).to eq(0)
      expect(batch.reload.metadata["modules"]["ghost-module"]["state"]).to eq("failed")
      # The lease taken for the unresolvable module must not be stranded.
      expect(System::CiRunnerLease.for_account(account).active.count).to eq(0)
    end

    it "walks an empty plan straight through to complete (vacuous — nothing needed rebuilding)" do
      batch = build_batch(modules: [])

      result = described_class.dispatch!(batch: batch)

      expect(result.dispatched).to eq(0)
      expect(batch.reload.status).to eq("complete")
    end
  end

  # BUILD_SHA is the ref the builder checks out from the MODULE SOURCE repo
  # (the one holding modules/<slug>/manifest.yaml). A CORE-triggered batch's
  # head_sha is a powernode-platform sha that does not exist there — the live
  # build died at `upload-pack: not our ref`. The core tree does NOT come from
  # BUILD_SHA anyway: stage15 clones the parent from GitHub's default branch.
  describe "BUILD_SHA for a core-sourced batch" do
    def core_batch(head_sha: "409c706ecd758a04f2237fdb8f2a1092106b903d")
      mod = create_module("powernode-hub-backend")
      plan = [ { module: mod.name, oci_ref: head_sha[0, 7] } ]
      System::ModuleBuildBatch.create_for(
        account: account, plan: plan, trigger: "manual",
        base_sha: "b3bc6908e9f9078797488f7e48e61970b78718b0", head_sha: head_sha,
        source_repo: "powernode/powernode-platform"
      )
    end

    def stub_module_source_tip(sha)
      # A real credential fixture, not a stubbed resolver: CiRunnerLeaseService
      # uses the same resolver, so stubbing the class breaks the lease path.
      provider = create(:git_provider, :gitea, account: account)
      create(:git_provider_credential, :gitea, account: account, provider: provider)
      fake = instance_double(::Devops::Git::ApiClient)
      allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake)
      # The lease path shares this client; it only needs to know runners are not
      # synced here.
      allow(fake).to receive(:supports_runners?).and_return(false)
      allow(fake).to receive(:get_repository).and_return({ "default_branch" => "develop" })
      allow(fake).to receive(:list_branches)
        .and_return([ { "name" => "develop", "commit" => { "id" => sha } } ])
      fake
    end

    it "builds the module source at ITS OWN tip, not the core sha" do
      seed_pool_member
      stub_module_source_tip("e8f31a9d1111111111111111111111111111aaaa")
      batch = core_batch

      described_class.dispatch!(batch: batch)

      task = System::Task.where(command: "ci.module_build", account: account).first
      expect(task.options["sha"]).to eq("e8f31a9d1111111111111111111111111111aaaa")
    end

    it "still tags the artifact with the CORE sha" do
      seed_pool_member
      stub_module_source_tip("e8f31a9d1111111111111111111111111111aaaa")
      batch = core_batch

      described_class.dispatch!(batch: batch)

      task = System::Task.where(command: "ci.module_build", account: account).first
      expect(task.options["oci_ref"]).to eq("409c706")
    end

    it "falls back to head_sha when the tip cannot be resolved (no worse than before)" do
      seed_pool_member
      provider = create(:git_provider, :gitea, account: account)
      create(:git_provider_credential, :gitea, account: account, provider: provider)
      fake = instance_double(::Devops::Git::ApiClient)
      allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake)
      # The lease path shares this client; it only needs to know runners are not
      # synced here.
      allow(fake).to receive(:supports_runners?).and_return(false)
      allow(fake).to receive(:get_repository).and_raise(StandardError, "gitea down")
      batch = core_batch

      described_class.dispatch!(batch: batch)

      task = System::Task.where(command: "ci.module_build", account: account).first
      expect(task.options["sha"]).to eq("409c706ecd758a04f2237fdb8f2a1092106b903d")
    end

    it "leaves a manifest-repo batch's BUILD_SHA exactly as before" do
      seed_pool_member
      mod = create_module("mod-a")
      batch = build_batch(modules: [ mod ], head_sha: "systemsha987654")

      described_class.dispatch!(batch: batch)

      task = System::Task.where(command: "ci.module_build", account: account).first
      expect(task.options["sha"]).to eq("systemsha987654")
    end
  end

  # IMP-26b7f0004a49 phase 1 (design option (a)) — record, at dispatch, WHICH
  # core commit this batch expects its Class-B artifacts to be assembled from.
  #
  # stage15.sh clones the parent with a bare `git clone --depth 1` against a
  # hardcoded github.com remote — unpinned, so the core it lands on is knowable
  # only after the fact. Without an expectation written down at dispatch there
  # is nothing to compare the artifact's stamped core sha AGAINST, and the
  # promote gate has no oracle.
  describe "expected core ref recorded at dispatch" do
    def core_batch(head_sha: "409c706ecd758a04f2237fdb8f2a1092106b903d")
      mod = create_module("powernode-hub-backend")
      plan = [ { module: mod.name, oci_ref: head_sha[0, 7] } ]
      System::ModuleBuildBatch.create_for(
        account: account, plan: plan, trigger: "manual",
        base_sha: "b3bc6908e9f9078797488f7e48e61970b78718b0", head_sha: head_sha,
        source_repo: "powernode/powernode-platform"
      )
    end

    def stub_git_api(default_branch: "develop", tip: nil)
      provider = create(:git_provider, :gitea, account: account)
      create(:git_provider_credential, :gitea, account: account, provider: provider)
      fake = instance_double(::Devops::Git::ApiClient)
      allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake)
      allow(fake).to receive(:supports_runners?).and_return(false)
      allow(fake).to receive(:get_repository).and_return({ "default_branch" => default_branch })
      allow(fake).to receive(:list_branches)
        .and_return([ { "name" => default_branch, "commit" => { "id" => tip } } ])
      fake
    end

    # A core-triggered batch EXISTS because core moved to head_sha. That is the
    # strongest expectation available and costs no network call.
    it "uses the batch's own head_sha for a core-sourced batch" do
      seed_pool_member
      stub_git_api(tip: "e8f31a9d1111111111111111111111111111aaaa")
      batch = core_batch

      described_class.dispatch!(batch: batch)

      expect(batch.reload.metadata["expected_core_sha"])
        .to eq("409c706ecd758a04f2237fdb8f2a1092106b903d")
    end

    # An extension-triggered / manual / CVE batch's head_sha is NOT a core sha,
    # so the expectation has to come from the core repo's own tip — resolved
    # from the AUTHORITATIVE remote, which is what a lagging GitHub mirror will
    # then fail to match.
    it "resolves the core repo's default-branch tip for a non-core-sourced batch" do
      seed_pool_member
      stub_git_api(tip: "aa11bb22cc33dd44ee55ff6600778899aabbccdd")
      mod = create_module("powernode-hub-frontend")
      batch = build_batch(modules: [ mod ], head_sha: "systemsha987654")

      described_class.dispatch!(batch: batch)

      expect(batch.reload.metadata["expected_core_sha"])
        .to eq("aa11bb22cc33dd44ee55ff6600778899aabbccdd")
    end

    it "records WHICH repo the expectation came from, so a refusal is diagnosable" do
      seed_pool_member
      stub_git_api(tip: "aa11bb22cc33dd44ee55ff6600778899aabbccdd")
      mod = create_module("powernode-hub-frontend")
      batch = build_batch(modules: [ mod ], head_sha: "systemsha987654")

      described_class.dispatch!(batch: batch)

      expect(batch.reload.metadata["expected_core_repo"]).to eq("powernode/powernode-platform")
    end

    # NEVER fabricate an expectation. An unresolvable tip records nothing, and
    # the promote gate is then inert for that batch — exactly today's behaviour,
    # no worse. Recording a guess would refuse good builds forever.
    it "records NO expectation (rather than a guess) when the core tip cannot be resolved" do
      seed_pool_member
      provider = create(:git_provider, :gitea, account: account)
      create(:git_provider_credential, :gitea, account: account, provider: provider)
      fake = instance_double(::Devops::Git::ApiClient)
      allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake)
      allow(fake).to receive(:supports_runners?).and_return(false)
      allow(fake).to receive(:get_repository).and_raise(StandardError, "gitea down")
      mod = create_module("powernode-hub-frontend")
      batch = build_batch(modules: [ mod ], head_sha: "systemsha987654")

      described_class.dispatch!(batch: batch)

      expect(batch.reload.metadata).not_to have_key("expected_core_sha")
    end

    # #resolve_core_tip makes two blocking Gitea calls (10s connect + 30s read
    # each), and dispatch! runs synchronously from CiRunnerLeaseSweepService's
    # sweep loop. A batch with no Class-B module can never carry core content, so
    # paying that there would stall lease sweeping fleet-wide for nothing.
    it "does not touch the git API at all for a batch with no Class-B module" do
      seed_pool_member
      provider = create(:git_provider, :gitea, account: account)
      create(:git_provider_credential, :gitea, account: account, provider: provider)
      fake = instance_double(::Devops::Git::ApiClient)
      allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake)
      allow(fake).to receive(:supports_runners?).and_return(false)
      expect(fake).not_to receive(:get_repository)
      expect(fake).not_to receive(:list_branches)
      mod = create_module("runtime-go")
      batch = build_batch(modules: [ mod ], head_sha: "systemsha987654")

      described_class.dispatch!(batch: batch)

      expect(batch.reload.metadata).not_to have_key("expected_core_sha")
    end

    it "does not fail the dispatch when the core tip cannot be resolved" do
      seed_pool_member
      mod = create_module("powernode-hub-frontend")
      batch = build_batch(modules: [ mod ], head_sha: "systemsha987654")

      result = described_class.dispatch!(batch: batch)

      expect(result.ok?).to be true
      expect(result.dispatched).to eq(1)
    end

    # dispatch! is reachable more than once for a batch; the expectation is
    # pinned to the moment of dispatch and must not drift under it afterwards.
    it "does not re-resolve an expectation it already recorded" do
      seed_pool_member
      stub_git_api(tip: "aa11bb22cc33dd44ee55ff6600778899aabbccdd")
      mod = create_module("powernode-hub-frontend")
      batch = build_batch(modules: [ mod ], head_sha: "systemsha987654")
      described_class.dispatch!(batch: batch)

      allow(::Devops::Git::ApiClient).to receive(:for)
        .and_return(instance_double(::Devops::Git::ApiClient,
                                    supports_runners?: false,
                                    get_repository: { "default_branch" => "develop" },
                                    list_branches: [ { "name" => "develop",
                                                       "commit" => { "id" => "ffffffffffffffffffffffffffffffffffffffff" } } ]))
      described_class.dispatch!(batch: batch.reload)

      expect(batch.reload.metadata["expected_core_sha"])
        .to eq("aa11bb22cc33dd44ee55ff6600778899aabbccdd")
    end

    # The whole chain is worthless if the recorded expectation never reaches
    # the gate. This is the plumbing assertion — the terminal call, not a name.
    it "hands the recorded expectation to ModulePublicationProcessor at publish time" do
      seed_pool_member
      stub_git_api(tip: "e8f31a9d1111111111111111111111111111aaaa")
      batch = core_batch
      described_class.dispatch!(batch: batch)
      mod = account.system_node_modules.find_by(name: "powernode-hub-backend")

      task = System::Task.find_by(account: account, command: "ci.module_build")
      task.update!(status: "complete", completed_at: Time.current,
                   events: [ { "type" => "completed", "result" => { "oci_digest" => "sha256:abcd1234" } } ])

      allow(System::ModuleSigningService).to receive(:sign!)
        .and_return(System::ModuleSigningService::Result.new(ok?: true, oci_ref: "x", digest: "sha256:abcd1234"))
      expect(System::ModulePublicationProcessor).to receive(:process!)
        .with(hash_including(
                node_module: mod,
                native_build: hash_including(
                  expected_core_sha: "409c706ecd758a04f2237fdb8f2a1092106b903d"
                )
              ))
        .and_return(System::ModulePublicationProcessor::Result.new(ok?: true, node_module_version: nil))

      described_class.advance!(batch: batch.reload)
    end
  end

  # The dispatch-time half of the core-provenance protection. CoreProvenanceGate
  # already catches a stale-mirror build at PROMOTE — but only after a full
  # Class-B build has burned a builder, a lease and ~40 minutes. The expectation
  # is resolved from the AUTHORITATIVE remote (Gitea) while the artifact is
  # cloned from the PUBLIC MIRROR (github.com), so both tips are available on
  # this one code path and the cheap refusal is available here.
  describe "GitHub-mirror divergence pre-flight at dispatch" do
    let(:core_sha)   { "409c706ecd758a04f2237fdb8f2a1092106b903d" }
    let(:mirror_sha) { "b3bc6908e9f9078797488f7e48e61970b78718b0" }

    # A core-SOURCED batch's expectation is its own head_sha — no Gitea call at
    # all — so these examples isolate the mirror half of the comparison.
    def class_b_batch(head_sha: "409c706ecd758a04f2237fdb8f2a1092106b903d")
      mod = create_module("powernode-hub-backend")
      plan = [ { module: mod.name, oci_ref: head_sha[0, 7] } ]
      System::ModuleBuildBatch.create_for(
        account: account, plan: plan, trigger: "manual",
        base_sha: "b3bc6908e9f9078797488f7e48e61970b78718b0", head_sha: head_sha,
        source_repo: "powernode/powernode-platform"
      )
    end

    def mirror_at(sha)
      allow(::System::CoreMirrorPreflight).to receive(:resolve_mirror_tip).and_return(sha)
    end

    def build_tasks
      System::Task.where(account: account, command: "ci.module_build")
    end

    context "DIVERGED — both tips read, and they differ" do
      it "refuses the dispatch instead of burning a build" do
        seed_pool_member
        mirror_at(mirror_sha)
        batch = class_b_batch(head_sha: core_sha)

        result = described_class.dispatch!(batch: batch)

        expect(result.ok?).to be false
        expect(build_tasks.count).to eq(0)
      end

      it "leaves the batch terminal rather than queued, so no later sweep dispatches it" do
        seed_pool_member
        mirror_at(mirror_sha)
        batch = class_b_batch(head_sha: core_sha)

        described_class.dispatch!(batch: batch)

        expect(batch.reload.status).to eq("failed")
        expect(batch.metadata["modules"].values.map { |e| e["state"] }).to all(eq("failed"))
      end

      it "names BOTH remotes and BOTH shas where an operator will read them" do
        seed_pool_member
        mirror_at(mirror_sha)
        batch = class_b_batch(head_sha: core_sha)

        described_class.dispatch!(batch: batch)

        expect(batch.reload.error_message).to include("github.com/nodealchemy/powernode-platform")
        expect(batch.error_message).to include("powernode/powernode-platform")
        expect(batch.error_message).to include(mirror_sha[0, 7])
        expect(batch.error_message).to include(core_sha[0, 7])
      end

      it "records the divergence on the batch, distinguishably" do
        seed_pool_member
        mirror_at(mirror_sha)
        batch = class_b_batch(head_sha: core_sha)

        described_class.dispatch!(batch: batch)

        preflight = batch.reload.metadata["core_mirror_preflight"]
        expect(preflight["state"]).to eq("diverged")
        expect(preflight["mirror_sha"]).to eq(mirror_sha)
        expect(preflight["expected_sha"]).to eq(core_sha)
      end
    end

    # A batch is routinely MIXED — the planner's reverse-dependency expansion
    # turned one edit under agent/ into 22 modules. A Class-A module clones no
    # parent, so a stale mirror cannot reach its artifact; refusing it too
    # would be a REGRESSION against the promote gate, which withholds only the
    # Class-B version and lets its siblings publish.
    context "DIVERGED — a MIXED batch" do
      def mixed_batch(head_sha: "409c706ecd758a04f2237fdb8f2a1092106b903d")
        class_b = create_module("powernode-hub-backend")
        class_a = create_module("runtime-go")
        plan = [ class_b, class_a ].map { |m| { module: m.name, oci_ref: head_sha[0, 7] } }
        System::ModuleBuildBatch.create_for(
          account: account, plan: plan, trigger: "manual",
          base_sha: "b3bc6908e9f9078797488f7e48e61970b78718b0", head_sha: head_sha,
          source_repo: "powernode/powernode-platform"
        )
      end

      it "refuses ONLY the modules that clone core" do
        seed_pool_member
        seed_pool_member
        mirror_at(mirror_sha)
        batch = mixed_batch(head_sha: core_sha)

        described_class.dispatch!(batch: batch)

        states = batch.reload.metadata["modules"]
        expect(states["powernode-hub-backend"]["state"]).to eq("failed")
        expect(states["runtime-go"]["state"]).to eq("dispatched")
      end

      it "still reports the dispatch as refused" do
        seed_pool_member
        seed_pool_member
        mirror_at(mirror_sha)
        batch = mixed_batch(head_sha: core_sha)

        result = described_class.dispatch!(batch: batch)

        expect(result.ok?).to be false
      end

      it "leaves the refused module TERMINAL, so a later sweep cannot dispatch it" do
        seed_pool_member
        seed_pool_member
        mirror_at(mirror_sha)
        batch = mixed_batch(head_sha: core_sha)
        described_class.dispatch!(batch: batch)

        described_class.dispatch!(batch: batch.reload)

        expect(batch.reload.metadata["modules"]["powernode-hub-backend"]["state"]).to eq("failed")
        expect(System::Task.where(account: account, command: "ci.module_build").count).to eq(1)
      end
    end

    context "AGREED — both tips read, and they match" do
      it "dispatches normally" do
        seed_pool_member
        mirror_at(core_sha)
        batch = class_b_batch(head_sha: core_sha)

        result = described_class.dispatch!(batch: batch)

        expect(result.ok?).to be true
        expect(result.dispatched).to eq(1)
        expect(batch.reload.status).to eq("dispatched")
      end

      it "records agreement on the batch" do
        seed_pool_member
        mirror_at(core_sha)
        batch = class_b_batch(head_sha: core_sha)

        described_class.dispatch!(batch: batch)

        expect(batch.reload.metadata["core_mirror_preflight"]["state"]).to eq("agreed")
      end
    end

    # THE design point. Refusing on an unread mirror would brick every Class-B
    # build on a network blip — a strictly worse failure than the one being
    # fixed — and CoreProvenanceGate is still the backstop at promote.
    context "UNDETERMINED — the mirror could not be read" do
      it "does NOT refuse; it dispatches" do
        seed_pool_member
        mirror_at(nil)
        batch = class_b_batch(head_sha: core_sha)

        result = described_class.dispatch!(batch: batch)

        expect(result.ok?).to be true
        expect(result.dispatched).to eq(1)
        expect(batch.reload.status).to eq("dispatched")
      end

      it "records that the check was not performed — neither agreed nor diverged" do
        seed_pool_member
        mirror_at(nil)
        batch = class_b_batch(head_sha: core_sha)

        described_class.dispatch!(batch: batch)

        preflight = batch.reload.metadata["core_mirror_preflight"]
        expect(preflight["state"]).to eq("undetermined")
        expect(preflight["mirror_sha"]).to be_nil
      end

      it "does not refuse when the mirror read raises outright" do
        seed_pool_member
        allow(::System::CoreMirrorPreflight).to receive(:resolve_mirror_tip)
          .and_raise(StandardError, "egress denied")
        batch = class_b_batch(head_sha: core_sha)

        result = described_class.dispatch!(batch: batch)

        expect(result.ok?).to be true
        expect(batch.reload.status).to eq("dispatched")
      end
    end

    context "operator kill switch" do
      it "dispatches a diverged batch when the pre-flight is disabled" do
        seed_pool_member
        SiteSetting.set(::System::CoreMirrorPreflight::ENABLED_SETTING, "false", setting_type: "string")
        mirror_at(mirror_sha)
        batch = class_b_batch(head_sha: core_sha)

        result = described_class.dispatch!(batch: batch)

        expect(result.ok?).to be true
        expect(batch.reload.status).to eq("dispatched")
        expect(batch.metadata["core_mirror_preflight"]["state"]).to eq("disabled")
      end
    end

    # head_sha is validated for PRESENCE only and the MCP dispatch tool takes
    # it as a free string, so a core-sourced batch's expectation can be a
    # 7-char tag or a branch name. That says nothing about the mirror and must
    # never be read as a divergence.
    it "does not refuse a batch whose expectation is not a comparable commit identity" do
      seed_pool_member
      mirror_at(mirror_sha)
      batch = class_b_batch(head_sha: "409c706")

      result = described_class.dispatch!(batch: batch)

      expect(result.ok?).to be true
      expect(batch.reload.status).to eq("dispatched")
      expect(batch.metadata["core_mirror_preflight"]["state"]).to eq("unusable_expectation")
    end

    # The recorded-verdict guard is load-bearing on its OWN, for the case the
    # `planning?` guard cannot cover: a batch that stayed in `planning` after a
    # verdict was written. Without it the sweep pays the network call again on
    # every pass.
    it "does not re-check a batch still in planning that already recorded a verdict" do
      seed_pool_member
      mod = create_module("powernode-hub-backend")
      batch = build_batch(modules: [ mod ], head_sha: "409c706ecd758a04f2237fdb8f2a1092106b903d")
      batch.update!(metadata: batch.metadata.merge(
        "expected_core_sha"     => core_sha,
        "core_mirror_preflight" => { "state" => "agreed" }
      ))
      expect(::System::CoreMirrorPreflight).not_to receive(:check)

      described_class.dispatch!(batch: batch)

      expect(batch.reload.metadata["core_mirror_preflight"]).to eq({ "state" => "agreed" })
    end

    # Same latency argument as the expectation itself: dispatch! runs
    # synchronously from CiRunnerLeaseSweepService's sweep loop, and a batch
    # with no Class-B module can never carry core content.
    it "makes no mirror call at all for a batch with no Class-B module" do
      seed_pool_member
      expect(::System::CoreMirrorPreflight).not_to receive(:check)
      expect(::System::CoreMirrorPreflight).not_to receive(:resolve_mirror_tip)
      mod = create_module("runtime-go")
      batch = build_batch(modules: [ mod ], head_sha: "systemsha987654")

      result = described_class.dispatch!(batch: batch)

      expect(result.ok?).to be true
      expect(batch.reload.metadata).not_to have_key("core_mirror_preflight")
    end

    # The sweep re-dispatches every non-terminal batch that still has a queued
    # module, on a loop. Re-checking there would pay the network call over and
    # over AND could refuse a batch already half-built.
    it "does not re-check, or refuse, a batch that has already dispatched" do
      seed_pool_member
      mirror_at(core_sha)
      batch = class_b_batch(head_sha: core_sha)
      described_class.dispatch!(batch: batch)

      mirror_at(mirror_sha)
      described_class.dispatch!(batch: batch.reload)

      expect(batch.reload.status).to eq("dispatched")
      expect(batch.metadata["core_mirror_preflight"]["state"]).to eq("agreed")
    end
  end

  describe "#advance!" do
    def dispatch_single(mod, tag: "abc1234")
      batch = build_batch(modules: [ mod ], tag: tag)
      described_class.dispatch!(batch: batch)
      batch.reload
    end

    def complete_task!(task, result:)
      task.update!(status: "complete", completed_at: Time.current,
                   events: (task.events || []) + [ { "type" => "completed", "message" => "done",
                                                      "result" => result, "timestamp" => Time.current.iso8601 } ])
    end

    it "signs, publishes, marks the module succeeded, and releases the lease on a successful build" do
      seed_pool_member
      mod = create_module("mod-success")
      batch = dispatch_single(mod)
      task = System::Task.find_by(account: account, command: "ci.module_build")
      lease = System::CiRunnerLease.find_by(build_task_id: task.id)
      complete_task!(task, result: { "oci_digest" => "sha256:abcd1234", "built_from_sha" => batch.head_sha })

      sign_result = System::ModuleSigningService::Result.new(ok?: true, oci_ref: "irrelevant", digest: "sha256:abcd1234")
      publish_result = System::ModulePublicationProcessor::Result.new(ok?: true, node_module_version: nil)

      expect(System::ModuleSigningService).to receive(:sign!).with(
        oci_ref: "registry.example.com/powernode/mod-success:abc1234",
        expected_digest: "sha256:abcd1234",
        account: account,
        node_module_id: mod.id
      ).and_return(sign_result)
      expect(System::ModulePublicationProcessor).to receive(:process!)
        .with(node_module: mod, tag: "abc1234", promote: true, native_build: anything).and_return(publish_result)

      result = described_class.advance!(batch: batch)

      expect(result.succeeded).to eq(1)
      expect(result.failed).to eq(0)
      expect(batch.reload.status).to eq("complete")
      expect(batch.succeeded_count).to eq(1)
      expect(batch.metadata["modules"]["mod-success"]["state"]).to eq("succeeded")
      expect(lease.reload).to be_released
    end

    it "fails closed and retries when signing does not report ok? (never calls publish)" do
      seed_pool_member
      seed_pool_member # fresh lease for the retry
      mod = create_module("mod-badsig")
      batch = dispatch_single(mod)
      task = System::Task.find_by(account: account, command: "ci.module_build")
      lease = System::CiRunnerLease.find_by(build_task_id: task.id)
      complete_task!(task, result: { "oci_digest" => "sha256:mismatched" })

      sign_result = System::ModuleSigningService::Result.new(ok?: false, error: "registry digest does not match expected digest")
      allow(System::ModuleSigningService).to receive(:sign!).and_return(sign_result)
      expect(System::ModulePublicationProcessor).not_to receive(:process!)

      result = described_class.advance!(batch: batch)

      expect(result.retried).to eq(1)
      expect(result.succeeded).to eq(0)
      expect(batch.reload.metadata["modules"]["mod-badsig"]["state"]).to eq("queued")
      expect(batch.metadata["modules"]["mod-badsig"]["error"]).to include("signing failed")
      expect(lease.reload).to be_released # the failed attempt's lease is recycled regardless
    end

    it "retries a failed build on a fresh lease, then marks the module (and batch) failed once max_attempts is exhausted" do
      SiteSetting.set("system.module_builds.max_attempts", "2", setting_type: "integer")
      seed_pool_member
      seed_pool_member # 2nd member so the retry can get a fresh lease
      mod = create_module("mod-retry")
      batch = dispatch_single(mod)

      task1 = System::Task.find_by(account: account, command: "ci.module_build")
      lease1 = System::CiRunnerLease.find_by(build_task_id: task1.id)
      task1.update!(status: "failed", completed_at: Time.current, error_message: "build failed")

      result1 = described_class.advance!(batch: batch)
      expect(result1.retried).to eq(1)
      expect(lease1.reload).to be_released
      expect(batch.reload.metadata["modules"]["mod-retry"]["state"]).to eq("queued")

      # A later tick actually dispatches the retry (fresh lease + Task).
      result2 = described_class.advance!(batch: batch)
      expect(result2.dispatched).to eq(1)
      task2 = System::Task.where(command: "ci.module_build", account: account).where.not(id: task1.id).first
      expect(task2).to be_present
      expect(batch.reload.metadata["modules"]["mod-retry"]["attempts"]).to eq(2)

      task2.update!(status: "failed", completed_at: Time.current, error_message: "build failed again")
      result3 = described_class.advance!(batch: batch)

      expect(result3.failed).to eq(1)
      expect(result3.retried).to eq(0)
      expect(batch.reload.status).to eq("failed")
      # NOTE (flagged for Part A cross-check): ModuleBuildBatch#recompute_counts!
      # tallies member_tasks BY TASK, not by distinct module — a retried
      # module leaves 2 terminal-failed Task rows (one per attempt), so
      # failed_count here is 2, not 1. Per-MODULE truth (exactly one module,
      # terminally failed) lives in metadata["modules"], asserted below.
      expect(batch.failed_count).to eq(2)
      expect(batch.metadata["modules"]["mod-retry"]["state"]).to eq("failed")
    end

    it "is idempotent — a second call with nothing new to process is a no-op" do
      seed_pool_member
      mod = create_module("mod-idempotent")
      batch = dispatch_single(mod)
      task = System::Task.find_by(account: account, command: "ci.module_build")
      complete_task!(task, result: { "oci_digest" => "sha256:abcd" })

      sign_result = System::ModuleSigningService::Result.new(ok?: true, digest: "sha256:abcd")
      publish_result = System::ModulePublicationProcessor::Result.new(ok?: true)
      allow(System::ModuleSigningService).to receive(:sign!).and_return(sign_result)
      allow(System::ModulePublicationProcessor).to receive(:process!).and_return(publish_result)

      described_class.advance!(batch: batch)
      expect(System::ModuleSigningService).not_to receive(:sign!)

      result = described_class.advance!(batch: batch)
      expect(result.succeeded).to eq(0) # already resolved — not re-counted
      expect(batch.reload.status).to eq("complete")
    end

    it "produces a batch in `partial` when some modules succeed and others exhaust retries" do
      SiteSetting.set("system.module_builds.max_attempts", "1", setting_type: "integer")
      seed_pool_member
      seed_pool_member
      good = create_module("mod-good")
      bad = create_module("mod-bad")
      batch = build_batch(modules: [ good, bad ])
      described_class.dispatch!(batch: batch)

      good_task = System::Task.where(command: "ci.module_build", account: account)
                               .detect { |t| t.options["module"] == "mod-good" }
      bad_task = System::Task.where(command: "ci.module_build", account: account)
                              .detect { |t| t.options["module"] == "mod-bad" }
      complete_task!(good_task, result: { "oci_digest" => "sha256:good" })
      bad_task.update!(status: "failed", completed_at: Time.current, error_message: "nope")

      sign_result = System::ModuleSigningService::Result.new(ok?: true, digest: "sha256:good")
      publish_result = System::ModulePublicationProcessor::Result.new(ok?: true)
      allow(System::ModuleSigningService).to receive(:sign!).and_return(sign_result)
      allow(System::ModulePublicationProcessor).to receive(:process!).and_return(publish_result)

      result = described_class.advance!(batch: batch)

      expect(result.succeeded).to eq(1)
      expect(result.failed).to eq(1)
      expect(batch.reload.status).to eq("partial")
      expect(batch.succeeded_count).to eq(1)
      expect(batch.failed_count).to eq(1)
    end
  end

  # Campaign 019f5885 inc10 — dual-run shadow mode. A shadow batch
  # (shadow: true) must publish with promote: false, so a native build
  # dispatched in "dual" mode never advances NodeModule#current_version_id —
  # the fleet keeps consuming exactly what the Gitea build published.
  describe "#advance! — shadow batches (inc10 dual-run)" do
    # Stub ONLY the registry manifest GET, mirroring
    # module_oci_ingest_service_spec's own seam. The "real
    # ModulePublicationProcessor" example below exists to prove the
    # promote: false contract through the genuine publish path, and that path
    # resolves the erofs LAYER digest over HTTP — which VCR (correctly) refuses
    # with no cassette, so publish failed with "erofs layer resolution failed"
    # and advance! reported succeeded: 0. That was a test-environment gap, not
    # a product defect: stubbing the HTTP boundary keeps the processor, the
    # layer selection and the promote decision all real.
    let(:shadow_erofs_digest) { "sha256:#{'e0' * 32}" }
    let(:shadow_manifest_doc) do
      {
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "layers" => [
          { "mediaType" => "application/vnd.powernode.erofs", "digest" => shadow_erofs_digest, "size" => 140_546_048 }
        ]
      }
    end

    before do
      System::ModuleOciIngestService.reset!
      System::ManifestFetchService.reset!
      allow_any_instance_of(System::ModuleOciIngestService)
        .to receive(:fetch_native_manifest).and_return(doc: shadow_manifest_doc)
    end

    def shadow_batch(modules:, tag: "native-abc1234")
      plan = modules.map { |m| { module: m.name, oci_ref: tag } }
      System::ModuleBuildBatch.create_for(account: account, plan: plan, trigger: "push",
                                          base_sha: "base0000", head_sha: "headsha1234567", shadow: true)
    end

    def complete_task!(task, result:)
      task.update!(status: "complete", completed_at: Time.current,
                   events: (task.events || []) + [ { "type" => "completed", "message" => "done",
                                                      "result" => result, "timestamp" => Time.current.iso8601 } ])
    end

    it "publishes with promote: false, still succeeding the module and releasing the lease" do
      seed_pool_member
      mod = create_module("mod-shadow")
      batch = shadow_batch(modules: [ mod ])
      described_class.dispatch!(batch: batch)
      task = System::Task.find_by(account: account, command: "ci.module_build")
      lease = System::CiRunnerLease.find_by(build_task_id: task.id)
      complete_task!(task, result: { "oci_digest" => "sha256:shadow1234" })

      sign_result = System::ModuleSigningService::Result.new(ok?: true, oci_ref: "irrelevant", digest: "sha256:shadow1234")
      publish_result = System::ModulePublicationProcessor::Result.new(ok?: true, node_module_version: nil)

      expect(System::ModuleSigningService).to receive(:sign!).with(
        oci_ref: "registry.example.com/powernode/mod-shadow:native-abc1234",
        expected_digest: "sha256:shadow1234",
        account: account,
        node_module_id: mod.id
      ).and_return(sign_result)
      expect(System::ModulePublicationProcessor).to receive(:process!)
        .with(node_module: mod, tag: "native-abc1234", promote: false, native_build: anything).and_return(publish_result)

      result = described_class.advance!(batch: batch)

      expect(result.succeeded).to eq(1)
      expect(batch.reload.status).to eq("complete")
      expect(batch.metadata["modules"]["mod-shadow"]["state"]).to eq("succeeded")
      expect(lease.reload).to be_released
    end

    it "never moves NodeModule#current_version_id (real ModulePublicationProcessor, not stubbed)" do
      allow(::System::DiskImageRegistryConfig).to receive(:registry_host).and_return("registry.example.com")
      seed_pool_member
      mod = create_module("mod-shadow-real")
      expect(mod.current_version_id).to be_nil
      batch = shadow_batch(modules: [ mod ])
      described_class.dispatch!(batch: batch)
      task = System::Task.find_by(account: account, command: "ci.module_build")
      complete_task!(task, result: { "oci_digest" => "sha256:shadow-real" })

      sign_result = System::ModuleSigningService::Result.new(ok?: true, digest: "sha256:shadow-real")
      allow(System::ModuleSigningService).to receive(:sign!).and_return(sign_result)

      result = described_class.advance!(batch: batch)

      expect(result.succeeded).to eq(1)
      expect(mod.reload.current_version_id).to be_nil
      expect(mod.versions.count).to eq(1) # ingested + recorded, just not promoted
    end
  end

  # Found live on ops-hub 2026-08-02. apply_module_manifest! read ONLY the
  # on-disk source tree (PlatformModuleManifestLoader::DEFAULT_ROOT). A
  # fleet-hosted control plane has no such tree — the extension module ships
  # /opt/powernode/extensions/system/** but not modules/ — so the read returned
  # blank, the method warned and returned, and ModuleService rows were never
  # synced. A manifest that ADDED a service (worker-web) therefore produced no
  # systemd unit while the build still reported success. The orchestrator's own
  # comment already recorded the same class of failure for hub-frontend's caddy.
  #
  # ManifestFetchService does handle platform modules (blank
  # gitea_repo_full_name falls through to ci_build_source_repo), so it is a
  # valid fallback — and a strictly better one, since it is pinned to the
  # build's head_sha where the on-disk read explicitly is not.
  describe "manifest apply when there is no on-disk source tree" do
    let(:mod) { create_module("powernode-hub-worker") }
    let(:yaml) do
      <<~YAML
        schema_version: 1
        name: powernode-hub-worker
        services:
          - name: sidekiq
            start_command: "/usr/local/bin/sidekiq-start.sh"
          - name: worker-web
            start_command: "/usr/local/bin/worker-web-start.sh"
      YAML
    end

    before do
      # Simulate the fleet-hosted box: no manifest on disk.
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with(/modules\/powernode-hub-worker\/manifest\.yaml/).and_return(false)
    end

    it "falls back to fetching the manifest at the batch head_sha" do
      batch = build_batch(modules: [ mod ], head_sha: "sysTip999")

      expect(::System::ManifestFetchService).to receive(:fetch)
        .with(hash_including(node_module: mod, ref: "sysTip999")).and_return(yaml)
      expect(::System::ManifestImportService).to receive(:import!)
        .with(hash_including(node_module: mod, yaml: yaml))
        .and_return(double(ok?: true, error: nil, validation_errors: []))

      described_class.new(batch: batch).send(:apply_module_manifest!, mod, mod.name)
    end

    it "escalates loudly when neither disk nor fetch yields a manifest" do
      batch = build_batch(modules: [ mod ])
      allow(::System::ManifestFetchService).to receive(:fetch).and_return(nil)

      orchestrator = described_class.new(batch: batch)
      expect(Rails.logger).to receive(:error).with(/manifest/i)
      expect(orchestrator).to receive(:emit_event)
        .with(a_string_matching(/manifest/), hash_including(severity: :high))

      orchestrator.send(:apply_module_manifest!, mod, mod.name)
    end

    it "does not fetch when the on-disk manifest is present" do
      allow(File).to receive(:file?).with(/modules\/powernode-hub-worker\/manifest\.yaml/).and_return(true)
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(/modules\/powernode-hub-worker\/manifest\.yaml/).and_return(yaml)
      batch = build_batch(modules: [ mod ])

      expect(::System::ManifestFetchService).not_to receive(:fetch)
      allow(::System::ManifestImportService).to receive(:import!)
        .and_return(double(ok?: true, error: nil, validation_errors: []))

      described_class.new(batch: batch).send(:apply_module_manifest!, mod, mod.name)
    end
  end

  # A batch had no kill switch: aborting a member Task only freed a builder,
  # and the next #advance! immediately leased another and dispatched the next
  # queued module (observed 2026-08-07 — a fresh builder ~2min after an
  # abort). Cancellation therefore has to bite in three independent places:
  # the batch's own state, the dispatch path, and the retry path. Asserting
  # only "status == cancelled" would pass while the batch kept building.
  describe "#cancel!" do
    it "stops the batch dispatching any further queued module" do
      SiteSetting.set("system.module_builds.max_concurrent_builders", "1", setting_type: "integer")
      2.times { seed_pool_member }
      mods  = Array.new(2) { |i| create_module("mod-cancel-#{i}") }
      batch = build_batch(modules: mods)

      described_class.dispatch!(batch: batch)
      expect(System::Task.where(command: "ci.module_build", account: account).count).to eq(1)
      expect(batch.reload.metadata["modules"].values.count { |m| m["state"] == "queued" }).to eq(1)

      described_class.cancel!(batch: batch, reason: "operator stopped the batch")

      expect(batch.reload.status).to eq("cancelled")
      expect(batch.cancelled_at).to be_present
      expect(batch.error_message).to eq("operator stopped the batch")

      # The load-bearing assertion: advancing a cancelled batch must not
      # lease a builder or create a task for the still-queued module.
      expect { described_class.advance!(batch: batch) }
        .not_to change { System::Task.where(command: "ci.module_build", account: account).count }
    end

    it "cancels the in-flight member task and releases its lease" do
      seed_pool_member
      mod   = create_module("mod-inflight")
      batch = build_batch(modules: [ mod ])

      described_class.dispatch!(batch: batch)
      task  = System::Task.find_by(command: "ci.module_build", account: account)
      lease = System::CiRunnerLease.for_account(account).find_by(build_task_id: task.id)
      expect(lease).not_to be_finished

      described_class.cancel!(batch: batch, reason: "wrong ref")

      expect(task.reload.status).to eq("cancelled")
      expect(lease.reload).to be_finished
    end

    it "does not re-queue a failed module for retry once cancelled" do
      seed_pool_member
      mod   = create_module("mod-noretry")
      batch = build_batch(modules: [ mod ])

      described_class.dispatch!(batch: batch)
      described_class.cancel!(batch: batch, reason: "stop")

      orchestrator = described_class.new(batch: batch.reload)
      entry = { "module" => "mod-noretry", "attempts" => 1, "state" => "dispatched" }

      expect(orchestrator.send(:attempt_retry!, entry)).to be(false)
      expect(entry["state"]).to eq("dispatched")
    end

    it "leaves a cancelled batch cancelled instead of resolving it to complete or failed" do
      seed_pool_member
      mod   = create_module("mod-terminal")
      batch = build_batch(modules: [ mod ])

      described_class.dispatch!(batch: batch)
      described_class.cancel!(batch: batch, reason: "stop")

      described_class.advance!(batch: batch)

      expect(batch.reload.status).to eq("cancelled")
    end

    it "refuses to cancel a batch that already finished" do
      mod   = create_module("mod-done")
      batch = build_batch(modules: [ mod ])
      batch.update!(status: "complete")

      result = described_class.cancel!(batch: batch, reason: "too late")

      expect(result.ok?).to be(false)
      expect(batch.reload.status).to eq("complete")
    end
  end
end
