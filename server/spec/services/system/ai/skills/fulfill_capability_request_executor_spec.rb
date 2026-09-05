# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 inc-M — the fulfill skill, refactored to a DURABLE STATE
# MACHINE. The skill now COMPOSES a plan and CREATES a System::FulfillmentRequest
# with the plan FROZEN; approval is the out-of-band composed→approved transition,
# and the orchestrator replays the frozen plan (never re-composes) — killing the
# TOCTOU where the approved plan and the executed plan could differ.
#
# Exit criterion unchanged: NL intent "give me a running memcached instance"
# (memcached is deliberately NOT a platform module — proves the from-scratch
# path). Externals mocked at their seams; orchestration + template authoring +
# closure dry-run + lease run for real.
RSpec.describe System::Ai::Skills::FulfillCapabilityRequestExecutor do
  let(:account)  { create(:account) }

  # APO-1c (IMP-7e2bdc1774e4). This executor declares `requires_approval: true`,
  # and BaseSkillExecutor#execute now resolves Ai::InterventionPolicy BEFORE
  # #perform — an unconfigured category defaults to require_approval, so every
  # example below would park an approval instead of performing. These examples
  # are about what #perform DOES, so an operator policy puts the gate on its
  # proceed branch rather than removing it: the real entry point still runs.
  # See spec/support/skill_gate_helpers.rb.
  before { auto_execute_skill_policy!(account, described_class) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:repo)     { create(:system_package_repository, account: account, name: "ubuntu-noble") }
  let!(:region)  { create(:system_provider_region, account: account, enabled: true) }
  let!(:itype)   { create(:system_provider_instance_type, account: account) }

  let(:request_text) { "give me a running memcached instance" }
  let(:exec)         { described_class.new(account: account) }

  let!(:base_os) do
    create(:system_node_module, account: account, node_platform: platform, category: category,
           name: described_class::DEFAULT_BASE_OS_MODULE_NAME)
  end
  let!(:memcached_module) do
    create(:system_node_module, account: account, node_platform: platform, category: category, name: "memcached")
  end

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

  before do
    # Semantic ranking: request orthogonal to every module → the memcached gap fires.
    allow_any_instance_of(::Ai::Memory::EmbeddingService).to receive(:generate) do |_svc, text|
      text.to_s == request_text ? [ 1.0, 0.0 ] : [ 0.0, 1.0 ]
    end
    # Gap bridge → a memcached package in the accessible repo.
    allow_any_instance_of(System::Ai::Skills::DiscoverPackagesByIntentExecutor)
      .to receive(:execute).and_return(
        { success: true,
          data: { results: [ { name: "memcached", package_id: "pkg-mc", repository_id: repo.id } ],
                  confidence: "high" } }
      )
  end

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

  def stub_smoke_ok!
    allow(::System::ModuleSmokeProbe).to receive(:run).and_return(
      ::System::ModuleSmokeProbe::Result.new(ok?: true, checks: [])
    )
  end

  describe ".descriptor" do
    it "declares the consolidated approval + high blast radius and binds the NL + autonomy agents" do
      d = described_class.descriptor
      expect(d[:requires_approval]).to be true
      expect(d[:blast_radius]).to eq(:high)
      entry = System::Ai::Skills::SkillBindings.by_skill.find { |r| r[:executor] == described_class }
      expect(entry[:agents]).to include("system-concierge", "fleet-autonomy")
    end
  end

  describe "compose (no approval) — creates a DURABLE composed request, ZERO side effects" do
    it "returns the plan + fulfillment_request_id and performs no side effects" do
      expect(::System::PackageModuleMaterializer).not_to receive(:call)
      templates_before = ::System::NodeTemplate.where(account: account).count

      r = exec.execute(request: request_text) # approved defaults false

      expect(r[:success]).to be true
      data = r[:data]
      expect(data[:executed]).to be false
      expect(data[:requires_approval]).to be true
      expect(data[:state]).to eq("composed")
      expect(data[:fulfillment_request_id]).to be_present
      expect(data[:template_id]).to be_nil

      # The durable record exists in `composed` with the plan FROZEN — including a
      # replayable `execution` context (the TOCTOU fix).
      fr = ::System::FulfillmentRequest.find(data[:fulfillment_request_id])
      expect(fr).to be_composed
      expect(fr.plan.dig("execution", "gaps").first["package"]).to eq("memcached")
      expect(fr.plan.dig("closure", "all")).to include("materialize:memcached")
      expect(fr.plan.dig("closure", "first")).to include(base_os.name)
      expect(fr.plan.dig("closure", "unresolved")).to eq(0)

      # No template / instance materialized.
      expect(::System::NodeTemplate.where(account: account).count).to eq(templates_before)
    end

    it "defaults count to 1 and caps it via SiteSetting system.fulfill.max_instances" do
      ::SiteSetting.set("system.fulfill.max_instances", "3", setting_type: "integer")

      capped = exec.execute(request: request_text, count: 10)
      expect(capped[:data][:plan].dig("instances", "count")).to eq(3)
      expect(capped[:data][:plan].dig("instances", "max")).to eq(3)

      defaulted = exec.execute(request: request_text)
      expect(defaulted[:data][:plan].dig("instances", "count")).to eq(1)
    end

    it "classifies the template mutation as the low-risk NEW-template path" do
      t = exec.execute(request: request_text)[:data][:plan]["template"]
      expect(t["new_template"]).to be true
      expect(t["mutation_requires_approval"]).to be false
    end
  end

  describe "authoring gaps — 'a human must author this' is carried, never dropped" do
    before do
      # Discovery finds NOTHING for the request → gap_for_capability returns an
      # author_module gap instead of a materialize gap.
      allow_any_instance_of(System::Ai::Skills::DiscoverPackagesByIntentExecutor)
        .to receive(:execute).and_return({ success: true, data: { results: [], confidence: nil } })
    end

    it "freezes author_module gaps into the plan and surfaces them in the payload" do
      r = exec.execute(request: request_text)

      expect(r[:success]).to be true
      plan = r[:data][:plan]
      expect(plan["unresolved_gaps"]).to be_present
      gap = plan["unresolved_gaps"].first
      expect(gap["action"]).to eq("author_module")
      expect(gap["capability"]).to be_present
      expect(gap["reason"]).to include("no matching package")
      # Nothing materializable — and the executable context stays materialize-only.
      expect(plan["materialize"]).to eq([])
      expect(plan.dig("execution", "gaps")).to eq([])
      expect(r[:data][:unresolved_gaps]).to eq(plan["unresolved_gaps"])
      # The closure block is what the approver reads for bulk-op safety
      # (total/first/last/all) — an unresolved gap is invisible there unless
      # its count rides along too.
      expect(plan.dig("closure", "unresolved")).to eq(plan["unresolved_gaps"].size)

      # Frozen on the durable row, so the out-of-band approver sees it.
      fr = ::System::FulfillmentRequest.find(r[:data][:fulfillment_request_id])
      expect(fr.plan["unresolved_gaps"]).to eq(plan["unresolved_gaps"])
    end

    it "withholds autonomous inline approval and PARKS the decision on the row" do
      expect(::System::PackageModuleMaterializer).not_to receive(:call)

      r = exec.execute(request: request_text, approved: true)

      expect(r[:success]).to be true
      expect(r[:data][:state]).to eq("composed")
      expect(r[:data][:executed]).to be false
      expect(r[:data][:approval_withheld_reason]).to include("unresolved").and include("author_module")

      # The trail survives beyond the return value (honest "did not silently
      # skip"): parked on the row, visible in the payload.
      fr = ::System::FulfillmentRequest.find(r[:data][:fulfillment_request_id])
      park = Array(fr.parked).find { |p| p["step"] == "autonomous_approval" }
      expect(park).to be_present
      expect(park["reason"]).to eq(r[:data][:approval_withheld_reason])
      expect(r[:data][:parked]).to include(park)
    end

    it "classifies a discovery OUTAGE as discovery_unavailable, not author_module" do
      allow_any_instance_of(System::Ai::Skills::DiscoverPackagesByIntentExecutor)
        .to receive(:execute).and_return({ success: false, error: "embedding service down" })

      r = exec.execute(request: request_text, approved: true)

      gap = r[:data][:plan]["unresolved_gaps"].first
      expect(gap["action"]).to eq("discovery_unavailable")
      expect(gap["reason"]).to include("retry")
      expect(r[:data][:state]).to eq("composed")
      expect(r[:data][:approval_withheld_reason]).to include("discovery_unavailable")
    end

    it "partitions a MIXED gap set: materialize rides execution, unresolved rides the plan, approval still withheld" do
      # Keep this request orthogonal to every module too, so neither phrase is
      # covered by reuse and BOTH go through gap resolution.
      allow_any_instance_of(::Ai::Memory::EmbeddingService).to receive(:generate) do |_svc, text|
        text.to_s == "memcached and quantumfoo" ? [ 1.0, 0.0 ] : [ 0.0, 1.0 ]
      end
      allow_any_instance_of(System::Ai::Skills::DiscoverPackagesByIntentExecutor)
        .to receive(:execute) do |_ex, intent:, **|
          if intent.to_s.include?("memcached")
            { success: true,
              data: { results: [ { name: "memcached", package_id: "pkg-mc", repository_id: repo.id } ],
                      confidence: "high" } }
          else
            { success: true, data: { results: [], confidence: nil } }
          end
        end
      expect(::System::PackageModuleMaterializer).not_to receive(:call)

      r = exec.execute(request: "memcached and quantumfoo", approved: true)

      plan = r[:data][:plan]
      expect(plan["materialize"].map { |g| g["package"] }).to eq([ "memcached" ])
      expect(plan.dig("execution", "gaps").map { |g| g["package"] }).to eq([ "memcached" ])
      expect(plan["unresolved_gaps"].map { |g| g["capability"] }).to eq([ "quantumfoo" ])
      expect(plan["unresolved_gaps"].first["action"]).to eq("author_module")
      # One materializable gap does NOT excuse the unresolved one — and it must
      # not make the unresolved gap disappear from the closure count either.
      expect(plan.dig("closure", "unresolved")).to eq(1)
      expect(r[:data][:state]).to eq("composed")
      expect(r[:data][:approval_withheld_reason]).to include("1 author_module")
    end

    it "still auto-approves when every gap is materializable (no unresolved gaps)" do
      allow_any_instance_of(System::Ai::Skills::DiscoverPackagesByIntentExecutor)
        .to receive(:execute).and_return(
          { success: true,
            data: { results: [ { name: "memcached", package_id: "pkg-mc", repository_id: repo.id } ],
                    confidence: "high" } }
        )
      stub_fresh_provision!
      stub_smoke_ok!
      allow(::System::PackageModuleMaterializer).to receive(:call).and_return(materializer_result)

      r = exec.execute(request: request_text, approved: true)

      expect(r[:data][:state]).to eq("ready")
      expect(r[:data][:approval_withheld_reason]).to be_nil
      expect(r[:data][:plan]["unresolved_gaps"]).to eq([])
    end
  end

  describe "out-of-band approval kills the TOCTOU" do
    it "the orchestrator replays the FROZEN plan — compose is NEVER re-run across the approval boundary" do
      r = exec.execute(request: request_text) # composes ONCE, freezes the plan
      fr = ::System::FulfillmentRequest.find(r[:data][:fulfillment_request_id])

      # Approve out-of-band + advance: no re-compose may happen (what executes is
      # the persisted plan, not a fresh composition).
      expect_any_instance_of(System::Ai::Skills::ModuleComposeExecutor).not_to receive(:execute)
      allow(::System::PackageModuleMaterializer).to receive(:call).and_return(materializer_result)
      stub_fresh_provision!
      stub_smoke_ok!

      fr.approve!
      ::System::FulfillmentAdvanceOrchestrator.advance!(request: fr)
      fr.reload

      expect(fr).to be_ready
      expect(fr.materialized_modules).to eq([ "memcached" ]) # the FROZEN package
    end
  end

  describe "approved: true (autonomous) — create + approve + drive the first advance inline" do
    before { stub_smoke_ok! }

    it "fulfills the memcached request end-to-end from the frozen plan" do
      stub_fresh_provision!
      allow(::System::PackageModuleMaterializer).to receive(:call).and_return(materializer_result)

      r = exec.execute(request: request_text, approved: true)

      expect(r[:success]).to be true
      data = r[:data]
      expect(data[:state]).to eq("ready")
      expect(data[:executed]).to be true
      expect(data[:fulfillment_request_id]).to be_present
      expect(data[:reused_modules]).to be_empty
      expect(data[:materialized_modules]).to eq([ "memcached" ])
      expect(data[:build_batch_id]).to eq(batch.id)

      # instance carries the fulfill modules + a first-class task-scoped lease.
      instance = ::System::NodeInstance.find(data[:instance_id])
      assigned = instance.node.node_module_assignments.map { |a| a.node_module.name }
      expect(assigned).to include(base_os.name, "memcached")
      expect(instance.lease_class).to eq("task_scoped")
      expect(data[:lease]["task_scoped"]).to be true
      expect(data[:smoke]["ok"]).to be true
    end

    it "stops at the build barrier (returns state building) when the batch has not finished — no sleep, no provision" do
      pending_batch = ::System::ModuleBuildBatch.create_for(
        account: account, plan: [ { module: "memcached", oci_ref: "abc" } ],
        trigger: "package", base_sha: "snap", head_sha: "snap"
      )
      pending_result = ::System::PackageModuleMaterializer::Result.new(
        top_level_module: memcached_module, dependency_modules: [], recommends_modules: [],
        dependencies_created: [], build_dispatches: [ { batch_id: pending_batch.id } ],
        build_batch: pending_batch, baseline_excluded: [], base_os_requires: nil, warnings: [], errors: []
      )
      allow(::System::PackageModuleMaterializer).to receive(:call).and_return(pending_result)
      expect_any_instance_of(System::Ai::Skills::ProvisionFullStackExecutor).not_to receive(:execute)

      r = exec.execute(request: request_text, approved: true)

      expect(r[:data][:state]).to eq("building")
      expect(r[:data][:executed]).to be false
      expect(r[:data][:template_id]).to be_nil
    end
  end
end
