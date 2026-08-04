# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 inc2 §4.3.3 — ModuleSmokeVerifyExecutor. The live
# instance-compose + health-probe calls need the real fleet/pool (PARKED —
# see ModuleSmokeProbe's class doc), so both InstancePoolService.acquire!
# and System::ModuleSmokeProbe.run are mocked throughout; only the DB-level
# orchestration (template composition, Task creation) runs for real.
RSpec.describe System::Ai::Skills::ModuleSmokeVerifyExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  let!(:target_module) do
    create(:system_node_module, account: account, node_platform: platform, category: category, name: "nginx-fresh")
  end
  let!(:base_os_module) do
    create(:system_node_module, account: account, node_platform: platform, category: category,
           name: described_class::DEFAULT_BASE_OS_MODULE_NAME)
  end

  let(:exec) { described_class.new(account: account) }

  before do
    allow(::System::InstancePoolService).to receive(:acquire!).with(account: account).and_return(instance)
  end

  describe ".descriptor" do
    it "is read-shape — no operator approval required" do
      expect(described_class.descriptor[:requires_approval]).to eq(false)
    end
  end

  describe "bindings" do
    it "binds to Fleet Autonomy and System Concierge" do
      entry = System::Ai::Skills::SkillBindings.by_skill.find { |r| r[:executor] == described_class }
      expect(entry).not_to be_nil
      expect(entry[:agents]).to include("Fleet Autonomy", "System Concierge")
    end
  end

  describe "#execute" do
    context "input validation" do
      it "fails fast without module_name or module_id" do
        result = exec.execute
        expect(result[:success]).to be false
        expect(result[:error]).to match(/module_name or module_id is required/)
      end

      it "fails when the module isn't found" do
        result = exec.execute(module_name: "does-not-exist")
        expect(result[:success]).to be false
        expect(result[:error]).to match(/module not found/)
      end

      it "fails when the base-os module isn't found" do
        base_os_module.destroy!
        result = exec.execute(module_name: target_module.name)
        expect(result[:success]).to be false
        expect(result[:error]).to match(/base-os module not found/)
      end
    end

    context "when the pool has no ready members" do
      before do
        allow(::System::InstancePoolService).to receive(:acquire!)
          .and_raise(::System::InstancePoolService::NoReadyMembersError, "pool empty")
      end

      it "surfaces a failure instead of raising" do
        result = exec.execute(module_name: target_module.name)
        expect(result[:success]).to be false
        expect(result[:error]).to match(/no ready pool members/)
      end
    end

    context "on healthy mocks" do
      before do
        allow(::System::ModuleSmokeProbe).to receive(:run)
          .with(instance: instance, node_module: target_module, base_os_module_name: base_os_module.name)
          .and_return(
            System::ModuleSmokeProbe::Result.new(
              ok?: true,
              checks: %w[unit_active health_endpoint ldd_closure].map do |name|
                System::ModuleSmokeProbe::CheckResult.new(name: name, pass: true, detail: "ok")
              end
            )
          )
      end

      it "returns a well-formed passing smoke report and queues the on-node sync" do
        result = exec.execute(module_name: target_module.name)

        expect(result[:success]).to be true
        data = result[:data]
        expect(data[:ok]).to be true
        expect(data[:module_name]).to eq("nginx-fresh")
        expect(data[:base_os_module_name]).to eq(described_class::DEFAULT_BASE_OS_MODULE_NAME)
        expect(data[:instance_id]).to eq(instance.id)
        expect(data[:template_id]).to eq(template.id)
        expect(data[:checks].size).to eq(3)
        expect(data[:checks]).to all(include(pass: true))

        # The on-node re-apply WAS queued (the probe needs the module mounted)...
        expect(System::Task.where(operable: instance, command: "sync_modules")).to exist
      end

      it "does NOT permanently widen the acquired member's own (shared/pool) template" do
        # No explicit template_id → the acquired member's own template. A
        # transient smoke composes the pairing to probe, then tears exactly
        # those additions back out so the shared template is left untouched for
        # the next pool consumer (the mutation TemplateApprovalPolicy flags).
        exec.execute(module_name: target_module.name)

        expect(System::TemplateModule.where(node_template: template, node_module: target_module)).not_to exist
        expect(System::TemplateModule.where(node_template: template, node_module: base_os_module)).not_to exist
      end

      it "accepts module_id in place of module_name" do
        result = exec.execute(module_id: target_module.id)
        expect(result[:success]).to be true
        expect(result[:data][:module_name]).to eq("nginx-fresh")
      end
    end

    context "on a failing probe" do
      before do
        allow(::System::ModuleSmokeProbe).to receive(:run).and_return(
          System::ModuleSmokeProbe::Result.new(
            ok?: false,
            checks: [
              System::ModuleSmokeProbe::CheckResult.new(name: "unit_active", pass: true, detail: "ok"),
              System::ModuleSmokeProbe::CheckResult.new(name: "health_endpoint", pass: false, detail: "connection refused"),
              System::ModuleSmokeProbe::CheckResult.new(name: "ldd_closure", pass: true, detail: "ok")
            ]
          )
        )
      end

      it "returns a well-formed failing smoke report (still success: true — the report itself is the payload)" do
        result = exec.execute(module_name: target_module.name)

        expect(result[:success]).to be true
        expect(result[:data][:ok]).to be false
        failing = result[:data][:checks].find { |c| c[:name] == "health_endpoint" }
        expect(failing[:pass]).to be false
        expect(failing[:detail]).to match(/connection refused/)
      end
    end

    context "template resolution" do
      it "uses an explicit template_id instead of the instance's own template" do
        other_template = create(:system_node_template, account: account, node_platform: platform)
        allow(::System::ModuleSmokeProbe).to receive(:run).and_return(
          System::ModuleSmokeProbe::Result.new(ok?: true, checks: [])
        )

        result = exec.execute(module_name: target_module.name, template_id: other_template.id)

        expect(result[:success]).to be true
        expect(result[:data][:template_id]).to eq(other_template.id)
        expect(System::TemplateModule.where(node_template: other_template, node_module: target_module)).to exist
      end
    end

    context "caller-owned instance (instance_id given)" do
      let(:caller_template) { create(:system_node_template, account: account, node_platform: platform) }
      let(:caller_node)     { create(:system_node, account: account, node_template: caller_template) }
      let(:caller_instance) { create(:system_node_instance, :running, node: caller_node) }

      before do
        allow(::System::ModuleSmokeProbe).to receive(:run).and_return(
          System::ModuleSmokeProbe::Result.new(ok?: true, checks: [])
        )
      end

      it "verifies THAT instance without acquiring a second member or releasing the caller's" do
        # The caller (e.g. fulfill) owns the instance lifecycle — smoke must not
        # acquire its own member (the bug that verified the WRONG instance) nor
        # release/terminate the one it was handed.
        expect(::System::InstancePoolService).not_to receive(:acquire!)
        expect(::System::InstancePoolService).not_to receive(:release!)

        result = exec.execute(module_name: target_module.name,
                              instance_id: caller_instance.id, template_id: caller_template.id)

        expect(result[:success]).to be true
        expect(result[:data][:instance_id]).to eq(caller_instance.id)
        expect(result[:data][:template_id]).to eq(caller_template.id)
        expect(caller_instance.reload.status).to eq("running") # not terminated
      end

      it "fails cleanly when the given instance_id does not exist" do
        result = exec.execute(module_name: target_module.name,
                              instance_id: "00000000-0000-7000-8000-000000000000")
        expect(result[:success]).to be false
        expect(result[:error]).to match(/instance not found/)
      end
    end

    # compose_pairing! writes TemplateModule joins outside the assignment-path
    # guard. On the fulfill path (explicit template_id) those joins PERSIST and
    # become the new template's permanent baseline; on the pool path they are
    # transient but still queue a sync_modules Task against a live shared
    # template. Either way the pairing is authoring, and a pairing that
    # introduces an error-severity conflict has no valid smoke result to give.
    context "composition guard" do
      let(:other_category) { create(:system_node_module_category, account: account, name: "other-#{SecureRandom.hex(3)}") }

      before do
        allow(::System::ModuleSmokeProbe).to receive(:run).and_return(
          System::ModuleSmokeProbe::Result.new(ok?: true, checks: [])
        )
      end

      it "refuses a pairing that would introduce an error-severity conflict" do
        target_module.update!(variety: "instance")
        base_os_module.update!(variety: "instance")

        result = exec.execute(module_name: target_module.name)

        expect(result[:success]).to be false
        expect(result[:error]).to match(/instance_variety_collision/)
      end

      it "leaves no half-composed pairing behind when it refuses" do
        target_module.update!(variety: "instance")
        base_os_module.update!(variety: "instance")

        exec.execute(module_name: target_module.name)

        expect(System::TemplateModule.where(node_template: template)).not_to exist
        expect(System::Task.where(operable: instance, command: "sync_modules")).not_to exist
      end

      # Delta semantics, as everywhere else: a template that already collides
      # must still be smokeable, or one bad pool template blocks every smoke
      # that lands on it.
      it "smokes onto a template that already collides, when the pairing adds nothing new" do
        System::TemplateModule.create!(
          node_template: template,
          node_module: create(:system_node_module, account: account, node_platform: platform,
                              category: other_category, variety: "instance", name: "stuck-a")
        )
        System::TemplateModule.create!(
          node_template: template,
          node_module: create(:system_node_module, account: account, node_platform: platform,
                              category: other_category, variety: "instance", name: "stuck-b")
        )

        result = exec.execute(module_name: target_module.name)

        expect(result[:success]).to be true
      end

      it "does not charge the pairing for a module the template already carries" do
        # base-os is already assigned as an instance-variety module; the smoke
        # re-requests it, which compose_pairing! skips. Nothing is introduced,
        # so nothing may be refused.
        base_os_module.update!(variety: "instance")
        System::TemplateModule.create!(node_template: template, node_module: base_os_module)

        result = exec.execute(module_name: target_module.name)

        expect(result[:success]).to be true
      end
    end

    # base_os_module_name defaults to the same name as the module being
    # smoke-verified when the caller is smoking a base-os build itself — so
    # node_module and base_os_module resolve to the SAME TemplateModule
    # target. compose_pairing! must dedupe that pair instead of trying to
    # create the same (template, node_module) join twice.
    context "smoking the base-os module itself (base == target)" do
      before do
        allow(::System::ModuleSmokeProbe).to receive(:run).and_return(
          System::ModuleSmokeProbe::Result.new(ok?: true, checks: [])
        )
      end

      it "composes a single pairing and succeeds instead of raising a duplicate-join error" do
        result = exec.execute(module_name: base_os_module.name)

        expect(result[:success]).to be true
        expect(result[:data][:ok]).to be true
      end

      it "does not leak the join behind on the pool path (dedup keeps ensure-teardown reachable)" do
        exec.execute(module_name: base_os_module.name)

        expect(System::TemplateModule.where(node_template: template, node_module: base_os_module)).not_to exist
      end
    end

    context "pool release" do
      it "releases a claimed pooled instance back to its pool" do
        pool = System::InstancePool.create!(
          account: account, node_template: template, name: "smoke-pool",
          lifecycle_class: "ephemeral", status: "active",
          target_size: 1, min_size: 0, max_size: 1
        )
        instance.update!(instance_pool: pool, pool_state: "claimed")
        allow(::System::ModuleSmokeProbe).to receive(:run).and_return(
          System::ModuleSmokeProbe::Result.new(ok?: true, checks: [])
        )
        expect(::System::InstancePoolService).to receive(:release!).with(instance: instance, pool: pool)

        exec.execute(module_name: target_module.name)
      end

      it "does not attempt release for a non-pool instance" do
        allow(::System::ModuleSmokeProbe).to receive(:run).and_return(
          System::ModuleSmokeProbe::Result.new(ok?: true, checks: [])
        )
        expect(::System::InstancePoolService).not_to receive(:release!)

        exec.execute(module_name: target_module.name)
      end
    end
  end
end
