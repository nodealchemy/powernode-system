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

    # Provision seam — hand back the leased pool member.
    allow(::System::InstancePoolService).to receive(:acquire!).with(account: account).and_return(leased_instance)
    allow(::System::InstancePoolService).to receive(:release!)
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
    before do
      allow(::System::ModuleSmokeProbe).to receive(:run).and_return(
        ::System::ModuleSmokeProbe::Result.new(ok?: true, checks: [])
      )
    end

    it "fulfills the memcached request end-to-end" do
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

      # 1 leased instance with a task-scoped lease anchored on the pool claim.
      expect(data[:instance_id]).to eq(leased_instance.id)
      expect(data[:lease]["ttl_seconds"]).to eq(described_class::DEFAULT_LEASE_TTL_SECONDS)
      expect(data[:lease]["pool_acquired_at"]).to be_present
      expect(data[:lease]["reaper_governed"]).to be true
      lease = leased_instance.reload.config["fulfillment_lease"]
      expect(lease["task_scoped"]).to be true
      expect(lease["source"]).to eq("fulfill_capability_request")

      # smoke ran (probe mocked).
      expect(data[:smoke][:ok]).to be true
    end

    it "materializes the gap baseline-excluded and awaits the build batch" do
      expect(::System::PackageModuleMaterializer).to receive(:call)
        .with(hash_including(include_baseline: false)).and_return(materializer_result)

      r = exec.execute(request: request_text, approved: true)
      expect(r[:data][:parked]).to be_an(Array) # batch complete → no build park
      expect(r[:data][:parked].map { |p| p[:step] }).not_to include("module_build")
    end
  end
end
