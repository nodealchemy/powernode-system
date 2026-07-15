# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 inc3 — THE goal: fulfill an arbitrary NL capability request
# on-demand by composing custom modules → a template → a running instance.
#
# Exit criterion: NL intent "give me a running memcached instance" (memcached is
# deliberately NOT one of the platform modules — proves the from-scratch path).
# Externals are MOCKED at their seams (materializer build execution,
# ModuleBuildBatch completion, provision, smoke probe); the ORCHESTRATION runs
# for real (compose, gap-bridge, template authoring, closure dry-run, lease).
RSpec.describe System::Ai::Skills::FulfillCapabilityRequestExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:repo)     { create(:system_package_repository, account: account, name: "ubuntu-noble") }

  let(:request_text) { "give me a running memcached instance" }
  let(:exec)         { described_class.new(account: account) }

  # base-os exists (the platform baseline the new template composes atop).
  let!(:base_os) do
    create(:system_node_module, account: account, node_platform: platform, category: category,
           name: described_class::DEFAULT_BASE_OS_MODULE_NAME)
  end

  # The module the materializer will "produce" for the memcached gap.
  let!(:memcached_module) do
    create(:system_node_module, account: account, node_platform: platform, category: category, name: "memcached")
  end

  # A COMPLETE package build batch — await_build_batch returns immediately.
  let(:batch) do
    b = ::System::ModuleBuildBatch.create_for(
      account: account, plan: [ { module: "memcached", oci_ref: "abc1234" } ],
      trigger: "package", base_sha: "snap", head_sha: "snap"
    )
    b.update!(status: "complete", completed_at: Time.current)
    b
  end

  let(:materializer_result) do
    ::System::PackageModuleMaterializer::Result.new(
      top_level_module: memcached_module, dependency_modules: [], recommends_modules: [],
      dependencies_created: [], build_dispatches: [ { batch_id: batch.id } ], build_batch: batch,
      baseline_excluded: [ "libc6" ], base_os_requires: nil, warnings: [], errors: []
    )
  end

  # A leased pool member — proves the lease/TTL path (pool_acquired_at anchor).
  let(:seed_template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:seed_node)     { create(:system_node, account: account, node_template: seed_template) }
  let(:leased_instance) do
    inst = create(:system_node_instance, :running, node: seed_node)
    pool = ::System::InstancePool.create!(
      account: account, node_template: seed_template, name: "fulfill-pool",
      lifecycle_class: "ephemeral", status: "active", target_size: 1, min_size: 0, max_size: 1
    )
    inst.update!(instance_pool: pool, pool_state: "claimed", pool_acquired_at: Time.current)
    inst
  end

  before do
    # Semantic ranking: the request is orthogonal to every module → nothing
    # covers it → the memcached gap fires. (Deterministic, seed-independent.)
    allow_any_instance_of(::Ai::Memory::EmbeddingService).to receive(:generate) do |_svc, text|
      text.to_s == request_text ? [ 1.0, 0.0 ] : [ 0.0, 1.0 ]
    end

    # Gap bridge resolves to a memcached package in the accessible repo.
    allow_any_instance_of(System::Ai::Skills::DiscoverPackagesByIntentExecutor)
      .to receive(:execute).and_return(
        { success: true,
          data: { results: [ { name: "memcached", package_id: "pkg-mc", repository_id: repo.id } ],
                  confidence: "high" } }
      )
    # NOTE: the provision seam is stubbed per-test — FRESH provision via
    # stub_fresh_provision!, or a SCOPED pool acquire! in the pool test — so the
    # pool/build-timeout tests can assert the seam is NEVER touched.
  end

  describe ".descriptor" do
    it "declares the consolidated approval + high blast radius and binds the NL + autonomy agents" do
      d = described_class.descriptor
      expect(d[:requires_approval]).to be true
      expect(d[:blast_radius]).to eq(:high)
      entry = System::Ai::Skills::SkillBindings.by_skill.find { |r| r[:executor] == described_class }
      expect(entry[:agents]).to include("System Concierge", "Fleet Autonomy")
    end
  end

  describe "approval gate (BLOCKS without approval)" do
    it "returns the plan + requires_approval and performs NO side effects" do
      expect(::System::PackageModuleMaterializer).not_to receive(:call)
      templates_before = ::System::NodeTemplate.where(account: account).count

      r = exec.execute(request: request_text) # approved defaults false

      expect(r[:success]).to be true
      data = r[:data]
      expect(data[:executed]).to be false
      expect(data[:requires_approval]).to be true
      expect(data[:template_id]).to be_nil

      # Consolidated approval payload enumerates the closure (bulk-op safety).
      plan = data[:plan]
      expect(plan[:closure][:total]).to be >= 2
      expect(plan[:closure][:first]).to include(base_os.name)
      expect(plan[:closure][:all]).to include("materialize:memcached")
      expect(plan[:materialize].first[:package]).to eq("memcached")

      # No template/instance materialized.
      expect(::System::NodeTemplate.where(account: account).count).to eq(templates_before)
      expect(leased_instance.reload.config["fulfillment_lease"]).to be_nil
    end

    it "defaults count to 1 and caps it via SiteSetting system.fulfill.max_instances" do
      ::SiteSetting.set("system.fulfill.max_instances", "3", setting_type: "integer")

      capped = exec.execute(request: request_text, count: 10)
      expect(capped[:data][:plan][:instances][:count]).to eq(3)
      expect(capped[:data][:plan][:instances][:max]).to eq(3)

      defaulted = exec.execute(request: request_text)
      expect(defaulted[:data][:plan][:instances][:count]).to eq(1)
    end

    it "classifies the template mutation as the low-risk NEW-template path" do
      t = exec.execute(request: request_text)[:data][:plan][:template]
      expect(t[:new_template]).to be true
      expect(t[:mutation_requires_approval]).to be false
    end
  end

  describe "approved execution (exit criterion — mocked externals)" do
    # Region + type so the FRESH-provision path (the primary path) resolves.
    let!(:region) { create(:system_provider_region, account: account, enabled: true) }
    let!(:itype)  { create(:system_provider_instance_type, account: account) }

    before do
      allow(::System::ModuleSmokeProbe).to receive(:run).and_return(
        ::System::ModuleSmokeProbe::Result.new(ok?: true, checks: [])
      )
    end

    # FRESH provision seam: author N real instances on the fulfill template and
    # return their ids — the same contract ProvisionFullStackExecutor honors.
    # Only the tests that actually reach provision stub this (so the pool /
    # build-timeout tests can assert provision is NEVER called).
    def stub_fresh_provision!
      allow_any_instance_of(System::Ai::Skills::ProvisionFullStackExecutor)
        .to receive(:execute) do |_ex, template_id:, count:, **_kw|
          tmpl = ::System::NodeTemplate.find(template_id)
          ids = Array.new(count) do
            node = create(:system_node, account: account, node_template: tmpl)
            create(:system_node_instance, :running, node: node).id
          end
          { success: true, data: { outputs: { node_instance_ids: ids } } }
        end
    end

    it "fulfills the memcached request end-to-end — the instance CARRIES the fulfill modules" do
      stub_fresh_provision!
      expect(::System::PackageModuleMaterializer).to receive(:call)
        .with(hash_including(include_baseline: false, base_os_module_name: base_os.name, build_mode: :native))
        .and_return(materializer_result)

      r = exec.execute(request: request_text, approved: true)

      expect(r[:success]).to be true
      data = r[:data]
      expect(data[:executed]).to be true

      # reused nothing, materialized memcached from scratch.
      expect(data[:reused_modules]).to be_empty
      expect(data[:materialized_modules]).to eq([ "memcached" ])
      expect(data[:build_batch_id]).to eq(batch.id)

      # NEW template = [base-os, memcached]; closure dry-run resolved base-os.
      template = ::System::NodeTemplate.find(data[:template_id])
      expect(template.node_modules.map(&:name)).to include(base_os.name, "memcached")

      # THE fix: the leased instance actually carries the fulfill template's
      # modules — its node is bound to that template AND the assignment closure
      # was materialized (not a generic pool VM).
      instance = ::System::NodeInstance.find(data[:instance_id])
      expect(instance.node.node_template_id).to eq(template.id)
      assigned = instance.node.node_module_assignments.map { |a| a.node_module.name }
      expect(assigned).to include(base_os.name, "memcached")
      # the on-node sync was queued so the modules get applied to the live node.
      expect(::System::Task.where(operable: instance, command: "sync_modules")).to exist

      # task-scoped lease is present on the instance.
      expect(data[:lease]["ttl_seconds"]).to eq(described_class::DEFAULT_LEASE_TTL_SECONDS)
      lease = instance.reload.config["fulfillment_lease"]
      expect(lease["task_scoped"]).to be true
      expect(lease["source"]).to eq("fulfill_capability_request")

      # smoke ran against THIS instance (probe mocked); the leased instance is
      # not terminated by the smoke step.
      expect(data[:smoke][:ok]).to be true
      expect(instance.reload.status).to eq("running")
    end

    it "leases EVERY provisioned instance when count > 1 (no unleased orphans)" do
      stub_fresh_provision!
      allow(::System::PackageModuleMaterializer).to receive(:call).and_return(materializer_result)

      r = exec.execute(request: request_text, count: 3, approved: true)

      expect(r[:success]).to be true
      ids = r[:data][:instance_ids]
      expect(ids.size).to eq(3)
      # all N carry a fulfillment lease — none left dangling.
      ids.each do |iid|
        inst = ::System::NodeInstance.find(iid)
        expect(inst.config["fulfillment_lease"]).to be_present
        expect(inst.node.node_module_assignments.map { |a| a.node_module.name }).to include("memcached")
      end
      expect(r[:data][:leases].size).to eq(3)
    end

    it "re-templates a SCOPED fulfillment-pool member instead of handing it back generic" do
      ::SiteSetting.set("system.fulfill.pool_name", "fulfill-pool", setting_type: "string")
      # Scoped acquire returns the seeded pool member (bound to seed_template).
      allow(::System::InstancePoolService).to receive(:acquire!)
        .with(account: account, pool_name: "fulfill-pool", lifecycle_class: nil)
        .and_return(leased_instance)
      # No fresh provision should be needed for count 1.
      expect_any_instance_of(System::Ai::Skills::ProvisionFullStackExecutor).not_to receive(:execute)
      allow(::System::PackageModuleMaterializer).to receive(:call).and_return(materializer_result)

      r = exec.execute(request: request_text, approved: true)

      expect(r[:success]).to be true
      data = r[:data]
      expect(data[:instance_id]).to eq(leased_instance.id)

      # The pool member was RE-TEMPLATED onto the fulfill template + carries its
      # modules — not the pool's original seed_template.
      expect(leased_instance.node.reload.node_template_id).to eq(data[:template_id])
      assigned = leased_instance.node.node_module_assignments.map { |a| a.node_module.name }
      expect(assigned).to include(base_os.name, "memcached")

      # pool-anchored lease is reaper-governed (still a claimed pool member).
      expect(data[:lease]["pool_acquired_at"]).to be_present
      expect(data[:lease]["reaper_governed"]).to be true

      # smoke verified the SAME leased instance (not terminated).
      expect(data[:smoke][:ok]).to be true
      expect(leased_instance.reload.status).to eq("running")
    end

    it "does NOT touch a pool at all when no fulfillment pool is configured (no CI starvation)" do
      # Default: no system.fulfill.pool_name / lifecycle → acquire! must never
      # be called (an unscoped acquire could grab a ci-native-builders member).
      stub_fresh_provision!
      expect(::System::InstancePoolService).not_to receive(:acquire!)
      allow(::System::PackageModuleMaterializer).to receive(:call).and_return(materializer_result)

      r = exec.execute(request: request_text, approved: true)
      expect(r[:success]).to be true
      expect(r[:data][:executed]).to be true
    end

    it "materializes the gap baseline-excluded and awaits the build batch" do
      stub_fresh_provision!
      expect(::System::PackageModuleMaterializer).to receive(:call)
        .with(hash_including(include_baseline: false)).and_return(materializer_result)

      r = exec.execute(request: request_text, approved: true)
      expect(r[:data][:parked]).to be_an(Array) # batch complete → no build park
      expect(r[:data][:parked].map { |p| p[:step] }).not_to include("module_build")
    end

    it "STOPS before template/provision when the build batch does not finish" do
      # Non-terminal batch: never author a template or provision from an unbuilt
      # module (real cloud spend on a broken instance).
      pending_batch = ::System::ModuleBuildBatch.create_for(
        account: account, plan: [ { module: "memcached", oci_ref: "abc1234" } ],
        trigger: "package", base_sha: "snap", head_sha: "snap"
      )
      timeout_result = ::System::PackageModuleMaterializer::Result.new(
        top_level_module: memcached_module, dependency_modules: [], recommends_modules: [],
        dependencies_created: [], build_dispatches: [ { batch_id: pending_batch.id } ],
        build_batch: pending_batch, baseline_excluded: [ "libc6" ], base_os_requires: nil,
        warnings: [], errors: []
      )
      allow(::System::PackageModuleMaterializer).to receive(:call).and_return(timeout_result)
      # Bound the poll to a single, sleepless attempt so the spec is fast.
      ::SiteSetting.set("system.fulfill.build_poll_attempts", "1", setting_type: "integer")
      ::SiteSetting.set("system.fulfill.build_poll_interval_seconds", "0", setting_type: "integer")

      templates_before = ::System::NodeTemplate.where(account: account).count
      expect_any_instance_of(System::Ai::Skills::ProvisionFullStackExecutor).not_to receive(:execute)

      r = exec.execute(request: request_text, approved: true)

      expect(r[:success]).to be true
      data = r[:data]
      expect(data[:executed]).to be false
      expect(data[:template_id]).to be_nil
      expect(data[:instance_ids]).to eq([])
      expect(::System::NodeTemplate.where(account: account).count).to eq(templates_before)
      expect(data[:parked].map { |p| p[:step] }).to include("module_build")
    end
  end
end
