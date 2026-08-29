# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M6.B — ProvisionClusterExecutor skill.
RSpec.describe System::Ai::Skills::ProvisionClusterExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:exec)     { described_class.new(account: account) }

  describe ".descriptor" do
    it "advertises required inputs and structured outputs" do
      d = described_class.descriptor
      expect(d[:name]).to eq("provision_cluster")
      expect(d.dig(:inputs, :template_id, :required)).to be true
      expect(d.dig(:inputs, :count, :required)).to be true
      expect(d.dig(:outputs)).to include(:created_nodes, :provisioned, :failures)
      # IMP-334f0cd3e1e8 — pinned, because these three are the whole contract
      # with the plan-level readers and every rollback-carrying sibling
      # (provision_full_stack, scale_project, relocate_workload, attach_storage)
      # pins them too.
      expect(d.dig(:outputs, :outputs)).to eq(node_ids: [ :string ], node_instance_ids: [ :string ])
      expect(d[:rollback]).to eq(:rollback_provision_cluster)
      expect(d[:blast_radius]).to eq(:medium)
    end
  end

  describe "#execute" do
    context "with invalid count" do
      it "rejects 0" do
        r = exec.execute(template_id: template.id, count: 0,
                         provider_region_id: "r", provider_instance_type_id: "t")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/count must be/)
      end

      it "rejects above MAX_COUNT" do
        r = exec.execute(template_id: template.id, count: 100,
                         provider_region_id: "r", provider_instance_type_id: "t")
        expect(r[:success]).to be false
      end
    end

    context "in dry_run mode" do
      it "returns a plan without creating any nodes" do
        expect {
          r = exec.execute(template_id: template.id, count: 3,
                           provider_region_id: "r1", provider_instance_type_id: "t1",
                           name_prefix: "web", dry_run: true)
          expect(r[:success]).to be true
          expect(r[:data][:dry_run]).to be true
          expect(r[:data][:count]).to eq(3)
          expect(r[:data][:plan][:template_id]).to eq(template.id)
          expect(r[:data][:plan][:naming]).to eq("web-1..3")
          expect(r[:data][:plan][:estimated_steps]).to eq(6)
        }.not_to change(System::Node, :count)
      end
    end

    context "with a missing template" do
      it "returns failure on lookup" do
        r = exec.execute(template_id: SecureRandom.uuid, count: 1,
                         provider_region_id: "r", provider_instance_type_id: "t")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/template lookup failed/)
      end
    end

    context "in execute mode (provisioning stubbed at the service layer)" do
      let(:fake_instance) do
        instance_double("System::NodeInstance", id: SecureRandom.uuid, name: "x",
                        node_id: SecureRandom.uuid, variety: nil, status: "provisioning",
                        architecture: "amd64", private_ip_address: nil,
                        public_ip_address: nil, last_heartbeat_at: nil,
                        mtls_subject: nil, agent_version: nil,
                        gpu_count: 0, gpu_type: nil, gpu_memory_mb: nil)
      end
      let(:fake_result) do
        ::System::Runtime::Result.ok(data: { instance: fake_instance, cloud_instance_id: "ci-abc" })
      end

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance).and_return(fake_result)
      end

      it "creates N nodes and dispatches N provision calls" do
        r = exec.execute(template_id: template.id, count: 2,
                         provider_region_id: "r1", provider_instance_type_id: "t1")
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:count]).to eq(2)
        expect(d[:created_nodes].size).to eq(2)
        expect(d[:provisioned].size).to eq(2)
        expect(d[:failures]).to be_empty
        expect(::System::ProvisioningService).to have_received(:provision_instance).twice
      end
    end

    context "when provisioning partially fails" do
      let(:fake_instance) do
        instance_double("System::NodeInstance", id: SecureRandom.uuid, name: "x",
                        node_id: SecureRandom.uuid, variety: nil, status: "provisioning",
                        architecture: "amd64", private_ip_address: nil,
                        public_ip_address: nil, last_heartbeat_at: nil,
                        mtls_subject: nil, agent_version: nil,
                        gpu_count: 0, gpu_type: nil, gpu_memory_mb: nil)
      end
      let(:ok_result)  { ::System::Runtime::Result.ok(data: { instance: fake_instance, cloud_instance_id: "ci-1" }) }
      let(:bad_result) { ::System::Runtime::Result.err(error: "region unavailable") }

      before do
        call_count = 0
        allow(::System::ProvisioningService).to receive(:provision_instance) do
          call_count += 1
          call_count.odd? ? ok_result : bad_result
        end
      end

      it "marks the run as partial and surfaces failures" do
        r = exec.execute(template_id: template.id, count: 2,
                         provider_region_id: "r1", provider_instance_type_id: "t1")
        expect(r[:success]).to be true
        expect(r[:data][:partial]).to be true
        expect(r[:data][:provisioned].size).to eq(1)
        expect(r[:data][:failures].size).to eq(1)
        expect(r[:data][:failures].first[:step]).to eq("provision_instance")
        expect(r[:data][:failures].first[:error]).to match(/region unavailable/)
      end
    end
  end

  # IMP-334f0cd3e1e8 — THE PLAN-LEVEL CONTRACT.
  #
  # Every reader that grades or compensates a composed step addresses the
  # NESTED ids region, `outputs.node_instance_ids`:
  #   - Ai::Provisioning::VerificationService reads it twice — once for the
  #     `step_N_count` oracle (inputs.count vs produced ids) and once to build
  #     the live-reconciliation expectation list;
  #   - Ai::Provisioning::SkillCompositionRunner#rollback_kwargs merges that
  #     sub-hash up one level to form the rollback hook's flat kwargs;
  #   - Ai::Provisioning::PlanComposerService wires `depends_on_outputs` at
  #     the literal path "outputs.node_instance_ids".
  #
  # This executor returned a FLAT envelope with no nested `outputs` and no ids
  # at all, and `count` is a REQUIRED input — so `declared_instance_count` is
  # always positive, the count branch always ran with an EMPTY id list, and a
  # fully successful N-node cluster scored "provisioned 0/N" permanently while
  # not one of its instances ever reached live reconciliation.
  #
  # Driven end-to-end through the REAL VerificationService and the REAL
  # SkillCompositionRunner rather than by asserting on the envelope's own
  # keys: the defect is a disagreement BETWEEN this executor and those two
  # readers, and only a test that runs both halves can see it.
  describe "plan-level envelope contract (IMP-334f0cd3e1e8)" do
    let(:user)     { create(:user, account: account) }
    let(:ai_agent) { create(:ai_agent, account: account, creator: user, status: "active") }
    let(:goal) do
      Ai::AgentGoal.create!(account: account, agent: ai_agent, title: "Cluster goal",
                            goal_type: "creation", status: "pending", priority: 3,
                            progress: 0.0, success_criteria: {})
    end
    let(:plan) do
      Ai::GoalPlan.create!(account: account, goal: goal, agent: ai_agent,
                           status: "executing", version: 1, plan_data: {})
    end
    let(:mission) do
      create(:ai_mission, account: account, created_by: user, mission_type: "infrastructure",
                          configuration: { "plan" => { "plan_id" => plan.id } })
    end

    # REAL rows. The rollback resolves ids back to records through
    # NodeInstance.find_by, so an instance_double id makes the teardown loop
    # skip silently and every assertion below would pass vacuously.
    let(:instance_a) { create(:system_node_instance, account: account) }
    let(:instance_b) { create(:system_node_instance, account: account) }

    # Exactly what SkillCompositionRunner#mark_completed persists for a step:
    # the executor's `data` envelope under metadata["last_outputs"].
    def record_step!(envelope, count:, region_id:, status: "completed")
      plan.steps.create!(
        step_number: 1, step_type: "provisioning_skill", description: "provision cluster",
        status: status,
        execution_config: { "skill" => "provision_cluster", "on_failure" => "rollback",
                            "inputs" => { "count" => count, "provider_region_id" => region_id } },
        metadata: { "last_outputs" => envelope.deep_stringify_keys }
      )
    end

    def stub_verifier(reconciler)
      allow(::Powernode::ExtensionRegistry).to receive(:provider).and_call_original
      allow(::Powernode::ExtensionRegistry).to receive(:provider)
        .with(:provision_verifier).and_return(reconciler)
    end

    it "scores a fully successful cluster N/N and hands every instance to live reconciliation" do
      instances = [ instance_a, instance_b ]
      allow(::System::ProvisioningService).to receive(:provision_instance) do
        ::System::Runtime::Result.ok(data: { instance: instances.shift,
                                             cloud_instance_id: "ci-#{SecureRandom.hex(2)}" })
      end

      r = exec.execute(template_id: template.id, count: 2,
                       provider_region_id: "region-1", provider_instance_type_id: "t1")
      expect(r[:success]).to be true
      record_step!(r[:data], count: 2, region_id: "region-1")

      reconciled = []
      reconciler = double("verifier")
      allow(reconciler).to receive(:reconcile_instances) do |account:, expectations:|
        reconciled.concat(expectations)
        expectations.map { |e| { node_instance_id: e[:node_instance_id], ok: true, detail: "running" } }
      end
      stub_verifier(reconciler)

      result = ::Ai::Provisioning::VerificationService.new(account: account, mission: mission).verify

      count_check = result[:checks].find { |c| c[:name] == "step_1_count" }
      expect(count_check[:detail]).to eq("provisioned 2/2 instances")
      expect(count_check[:ok]).to be true

      # The other half of the defect: the expectation list is what reaches the
      # reconciler, so a flat envelope also means the instances are never
      # live-verified at all.
      expect(reconciled.map { |e| e[:node_instance_id] }).to match_array([ instance_a.id, instance_b.id ])
      expect(reconciled).to all(include(provider_region_id: "region-1"))
      expect(result[:healthy]).to be true
    end

    # COVERS THE WIRING, NOT THE DISPATCH — read this before inferring more.
    #
    # It calls rollback_step! directly over a step whose last_outputs hold a
    # partial run's ids, and proves the chain from there: descriptor lookup →
    # build_executor → rollback_kwargs flattening the nested `outputs` sub-hash
    # → the hook → terminate_instance on the real row.
    #
    # It does NOT prove production ever reaches that state. It cannot: a step
    # can never re-enter execute_step! (CLAIMABLE_STATUSES is %w[pending],
    # skill_composition_runner.rb:55/:576, and nothing anywhere resets a step
    # to pending — the adaptation lane APPENDS renumbered new steps rather than
    # re-running old ones), so `last_outputs` from a prior partial success is
    # not a reachable rollback source for this executor. The reachable dispatch
    # is the raise path, covered by the example below.
    it "tears down the instances a PARTIAL run created when the step is rolled back" do
      allow(::System::ProvisioningService).to receive(:provision_instance).and_return(
        ::System::Runtime::Result.ok(data: { instance: instance_a, cloud_instance_id: "ci-1" }),
        ::System::Runtime::Result.err(error: "region unavailable")
      )

      r = exec.execute(template_id: template.id, count: 2,
                       provider_region_id: "region-1", provider_instance_type_id: "t1")
      expect(r[:data][:partial]).to be true
      step = record_step!(r[:data], count: 2, region_id: "region-1", status: "failed")

      terminated = []
      allow(::System::ProvisioningService).to receive(:terminate_instance) do |instance:|
        terminated << instance
        ::System::Runtime::Result.ok
      end
      allow(MissionChannel).to receive(:broadcast_mission_event)

      runner = ::Ai::Provisioning::SkillCompositionRunner.new(account: account, mission: mission, plan: plan)
      expect(runner.rollback_step!(step)[:success]).to be true

      # The teardown itself: the ONE real instance the partial run stood up,
      # and not the untouched sibling.
      expect(terminated.map(&:id)).to eq([ instance_a.id ])
      expect(terminated.map(&:id)).not_to include(instance_b.id)

      # And the runner's own no-op detector agrees something was compensated —
      # an inert descriptor entry stamps `noop: true` here.
      expect(step.reload.result_summary["noop"]).to be_nil
    end

    # THE REAL DISPATCH. No hand-built fixture state: a pending step goes
    # through SkillCompositionRunner#execute_step!, a leg RAISES mid-loop after
    # one instance is already live, and the runner's own handle_failure →
    # rollback_step! path is what reaches the hook.
    #
    # The raise is not hypothetical, but the class matters: SystemFleetTool
    # #call rescues RecordNotFound, RecordInvalid, ArgumentError and
    # InvalidTransition into error results (:1758-1763), and BaseTool#execute
    # adds no rescue of its own around `call(params)`. So RecordNotUnique — a
    # real mid-loop node-name collision — unwinds straight through the tool and
    # through this executor, as do a DB StatementInvalid, a provider
    # Timeout::Error, the deny overlay's PermissionDeniedError (raised before
    # `call`), and the executor's own NoMethodError on a nil node.
    #
    # Before the loop guard, that raise reached BaseSkillExecutor#execute and
    # became a bare `failure(msg)`: no failure_outputs, empty rollback kwargs,
    # and `rolled_back` stamped over a live, billing instance.
    it "tears down what it had created when a leg RAISES mid-loop, via the runner's own dispatch" do
      calls = 0
      allow(::System::ProvisioningService).to receive(:provision_instance) do
        calls += 1
        raise ActiveRecord::RecordNotUnique, "duplicate node name mid-run" if calls > 1

        ::System::Runtime::Result.ok(data: { instance: instance_a, cloud_instance_id: "ci-1" })
      end

      terminated = []
      allow(::System::ProvisioningService).to receive(:terminate_instance) do |instance:|
        terminated << instance
        ::System::Runtime::Result.ok
      end
      allow(MissionChannel).to receive(:broadcast_mission_event)

      step = plan.steps.create!(
        step_number: 1, step_type: "provisioning_skill", description: "provision cluster",
        status: "pending",
        execution_config: { "skill" => "provision_cluster", "on_failure" => "rollback",
                            "inputs" => { "template_id" => template.id, "count" => 2,
                                          "provider_region_id" => "region-1",
                                          "provider_instance_type_id" => "t1" } }
      )

      runner = ::Ai::Provisioning::SkillCompositionRunner.new(account: account, mission: mission, plan: plan)
      outcome = runner.execute_step!(step)

      expect(outcome[:success]).to be false
      expect(outcome[:error]).to match(/duplicate node name mid-run/)

      # The teardown, reached with no fixture assistance at all.
      expect(terminated.map(&:id)).to eq([ instance_a.id ])
      expect(step.reload.result_summary["noop"]).to be_nil
    end
  end
end
