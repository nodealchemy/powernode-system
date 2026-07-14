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
        .with(node_module: mod, tag: "abc1234", promote: true).and_return(publish_result)

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
    before do
      System::ModuleOciIngestService.reset!
      System::ManifestFetchService.reset!
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
        .with(node_module: mod, tag: "native-abc1234", promote: false).and_return(publish_result)

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
end
