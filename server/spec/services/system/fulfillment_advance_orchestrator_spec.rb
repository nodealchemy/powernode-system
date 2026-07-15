# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 inc-M — System::FulfillmentAdvanceOrchestrator drives a
# durable System::FulfillmentRequest from `approved` to `ready` by REPLAYING the
# frozen plan (never re-composing), WAITING at the build barrier without sleeping,
# gating on budget/rate-limit, and rolling back on failure. Externals are mocked
# at their seams (materializer, provision, smoke probe); the ORCHESTRATION +
# template authoring + closure dry-run + lease run for real.
RSpec.describe System::FulfillmentAdvanceOrchestrator do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:repo)     { create(:system_package_repository, account: account, name: "ubuntu-noble") }
  let!(:region)  { create(:system_provider_region, account: account, enabled: true) }
  let!(:itype)   { create(:system_provider_instance_type, account: account) }

  let!(:base_os) do
    create(:system_node_module, account: account, node_platform: platform, category: category,
           name: System::Ai::Skills::FulfillCapabilityRequestExecutor::DEFAULT_BASE_OS_MODULE_NAME)
  end
  let!(:memcached_module) do
    create(:system_node_module, account: account, node_platform: platform, category: category, name: "memcached")
  end

  let(:complete_batch) do
    b = ::System::ModuleBuildBatch.create_for(
      account: account, plan: [ { module: "memcached", oci_ref: "abc1234" } ],
      trigger: "package", base_sha: "snap", head_sha: "snap"
    )
    b.update!(status: "complete", completed_at: Time.current)
    b
  end

  def materializer_result(batch:)
    ::System::PackageModuleMaterializer::Result.new(
      top_level_module: memcached_module, dependency_modules: [], recommends_modules: [],
      dependencies_created: [], build_dispatches: [ { batch_id: batch.id } ], build_batch: batch,
      baseline_excluded: [ "libc6" ], base_os_requires: nil, warnings: [], errors: []
    )
  end

  def default_gaps
    [ { "package" => "memcached", "repository_id" => repo.id, "reason" => "gap", "action" => "materialize" } ]
  end

  # An `approved` request carrying a FROZEN execution context — exactly what the
  # skill persists, minus the interactive compose.
  def approved_request(count: 1, gaps: default_gaps, reused: [], cost: { "hourly_total" => 0.02 })
    execution = {
      "base_os_module_id" => base_os.id, "base_os_module_name" => base_os.name,
      "reused_modules" => reused, "gaps" => gaps, "count" => count,
      "provider_region_id" => region.id, "provider_instance_type_id" => itype.id,
      "platform_id" => platform.id, "template_name" => "fulfill-memcached-#{SecureRandom.hex(3)}"
    }
    fr = ::System::FulfillmentRequest.create_composed!(
      account: account, request: "give me a running memcached instance",
      plan: { "execution" => execution, "cost_estimate" => cost }, cost_estimate: cost,
      reused_modules: reused.map { |m| m["name"] }, lease_ttl_seconds: 3600
    )
    fr.approve!
    fr
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

  describe "happy path (approved → ready), replaying the frozen plan" do
    before do
      allow(::System::PackageModuleMaterializer).to receive(:call).and_return(materializer_result(batch: complete_batch))
      stub_fresh_provision!
      stub_smoke_ok!
    end

    it "NEVER re-composes — it replays plan[execution] end-to-end" do
      # THE TOCTOU FIX: the orchestrator must not touch ModuleComposeExecutor.
      expect_any_instance_of(System::Ai::Skills::ModuleComposeExecutor).not_to receive(:execute)

      fr = approved_request
      result = described_class.advance!(request: fr)
      fr.reload

      expect(result.ok?).to be true
      expect(fr).to be_ready
    end

    it "materializes baseline-excluded, authors the NEW template, provisions a leased instance, smokes it" do
      expect(::System::PackageModuleMaterializer).to receive(:call)
        .with(hash_including(include_baseline: false, base_os_module_name: base_os.name, build_mode: :native))
        .and_return(materializer_result(batch: complete_batch))

      fr = approved_request
      described_class.advance!(request: fr)
      fr.reload

      expect(fr).to be_ready
      expect(fr.materialized_modules).to eq([ "memcached" ])
      expect(fr.build_batch_id).to eq(complete_batch.id)

      # NEW template = [base-os, memcached]; closure dry-run resolved base-os.
      template = ::System::NodeTemplate.find(fr.template_id)
      expect(template.node_modules.map(&:name)).to include(base_os.name, "memcached")

      # the leased instance actually carries the fulfill template's modules.
      instance = ::System::NodeInstance.find(fr.node_instance_ids.first)
      expect(instance.node.node_template_id).to eq(template.id)
      assigned = instance.node.node_module_assignments.map { |a| a.node_module.name }
      expect(assigned).to include(base_os.name, "memcached")
      expect(::System::Task.where(operable: instance, command: "sync_modules")).to exist

      # FIRST-CLASS task-scoped lease (the reified P0-A decorative lease).
      expect(instance.lifecycle_class).to eq("task_scoped")
      expect(instance.lease_expires_at).to be_present
      expect(instance.config.dig("fulfillment_lease", "task_scoped")).to be true
      expect(fr.expires_at).to be_present

      # smoke ran against THIS instance; not terminated.
      expect(fr.smoke["ok"]).to be true
      expect(instance.reload.status).to eq("running")
    end

    it "leases EVERY provisioned instance when count > 1 (no unleased orphans)" do
      fr = approved_request(count: 3)
      described_class.advance!(request: fr)
      fr.reload

      expect(fr.node_instance_ids.size).to eq(3)
      fr.node_instance_ids.each do |iid|
        inst = ::System::NodeInstance.find(iid)
        expect(inst.config["fulfillment_lease"]).to be_present
        expect(inst.lifecycle_class).to eq("task_scoped")
      end
    end
  end

  describe "the build barrier — WAIT without sleeping, then resume" do
    let(:pending_batch) do
      ::System::ModuleBuildBatch.create_for(
        account: account, plan: [ { module: "memcached", oci_ref: "abc" } ],
        trigger: "package", base_sha: "snap", head_sha: "snap"
      ) # stays in :planning (not finished)
    end

    it "stops in `building` while the batch is unfinished, then advances to ready once it completes" do
      allow(::System::PackageModuleMaterializer).to receive(:call).and_return(materializer_result(batch: pending_batch))

      fr = approved_request
      r1 = described_class.advance!(request: fr)
      fr.reload
      expect(r1.waiting).to be true
      expect(fr).to be_building
      expect(fr.template_id).to be_nil        # never author a template from an unbuilt closure
      expect(fr.node_instance_ids).to be_empty # and never provisioned

      # batch finishes out-of-band → the sweep re-ticks → resumes from `building`.
      pending_batch.update!(status: "complete", completed_at: Time.current)
      stub_fresh_provision!
      stub_smoke_ok!

      described_class.advance!(request: fr)
      fr.reload
      expect(fr).to be_ready
      expect(fr.template_id).to be_present
    end

    it "fails + rolls back when the batch terminates NOT-complete (partial/failed)" do
      failed_batch = ::System::ModuleBuildBatch.create_for(
        account: account, plan: [ { module: "memcached", oci_ref: "abc" } ],
        trigger: "package", base_sha: "snap", head_sha: "snap"
      )
      failed_batch.update!(status: "failed", failed_at: Time.current)
      allow(::System::PackageModuleMaterializer).to receive(:call).and_return(materializer_result(batch: failed_batch))
      expect_any_instance_of(System::Ai::Skills::ProvisionFullStackExecutor).not_to receive(:execute)

      fr = approved_request
      described_class.advance!(request: fr)
      fr.reload

      expect(fr).to be_failed
      expect(fr.error).to include("did not complete")
      expect(fr.template_id).to be_nil
    end
  end

  describe "budget + rate-limit gate (approved → materializing)" do
    it "parks on budget: hourly_total over system.fulfill.max_hourly_cost — stays approved, no materialize" do
      ::SiteSetting.set("system.fulfill.max_hourly_cost", "0.01", setting_type: "string")
      expect(::System::PackageModuleMaterializer).not_to receive(:call)

      fr = approved_request(cost: { "hourly_total" => 0.02 })
      described_class.advance!(request: fr)
      fr.reload

      expect(fr).to be_approved # did NOT advance
      expect(fr.gate_blocked?).to be true
      expect(fr.parked.map { |p| p["step"] }).to include("budget_gate")
    end

    it "parks on rate limit: account over system.fulfill.max_requests_per_hour" do
      ::SiteSetting.set("system.fulfill.max_requests_per_hour", "1", setting_type: "integer")
      # one prior request already STARTED this hour for the account.
      prior = approved_request
      prior.update_column(:materializing_at, 5.minutes.ago)
      expect(::System::PackageModuleMaterializer).not_to receive(:call)

      fr = approved_request
      described_class.advance!(request: fr)
      fr.reload

      expect(fr).to be_approved
      expect(fr.parked.map { |p| p["step"] }).to include("rate_limit_gate")
    end

    it "passes the gate when caps are unset / not exceeded" do
      allow(::System::PackageModuleMaterializer).to receive(:call).and_return(materializer_result(batch: complete_batch))
      stub_fresh_provision!
      stub_smoke_ok!

      fr = approved_request
      described_class.advance!(request: fr)
      expect(fr.reload).to be_ready
    end
  end

  describe "failure → rollback (every artifact torn down)" do
    it "terminates provisioned instances, destroys the orphan template, and fails" do
      allow(::System::PackageModuleMaterializer).to receive(:call).and_return(materializer_result(batch: complete_batch))
      stub_fresh_provision!
      # Smoke raises AFTER provisioning + template authoring → exercises full rollback.
      allow_any_instance_of(System::Ai::Skills::ModuleSmokeVerifyExecutor)
        .to receive(:execute).and_raise(RuntimeError, "smoke blew up")
      # Isolate rollback from the real provider.
      allow(::System::ProvisioningService).to receive(:terminate_instance)
        .and_return(instance_double("Result", success?: true))

      fr = approved_request
      described_class.advance!(request: fr)
      fr.reload

      expect(fr).to be_failed
      expect(fr.error).to include("smoke blew up")
      # instances were rolled back (terminate called for the provisioned instance).
      expect(::System::ProvisioningService).to have_received(:terminate_instance).at_least(:once)
      # orphan template destroyed.
      expect(::System::NodeTemplate.find_by(id: fr.template_id)).to be_nil
      # rollback recorded honestly on the row.
      expect(fr.parked.map { |p| p["step"] }).to include("rollback")
    end
  end
end
