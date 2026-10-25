# frozen_string_literal: true

require "rails_helper"

# c13-4 (operator ruling, 2026-10-24): system_return_pooled_instance and
# system_release_ci_runner gate ONLY the terminating path through
# Ai::Executors::DeferredToolCall, under the existing system.task.terminate
# category. A healthy return/release that recycles a member stays ungated.
#
#   system_release_ci_runner     force: true  (tears down a running build)
#   system_return_pooled_instance a member that still holds a live CI runner
#                                 lease (returning it terminates the VM under
#                                 the lease, bypassing the lease's own release)
RSpec.describe "c13-4 terminate/force paths of pool return and CI release park", type: :service do
  let(:account) { create(:account) }
  let!(:owner) { create(:user, account: account) } # first user: account owner
  let(:approver) { create(:user, account: account, permissions: %w[ai.autonomy.approve ai.agents.read]) }

  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform_record) }
  let(:region) { create(:system_provider_region, account: account) }
  let(:itype) { create(:system_provider_instance_type, account: account) }
  let(:pool) do
    ::System::InstancePool.create!(
      account: account, node_template: template, name: "c13-4-pool", target_size: 2, min_size: 0,
      max_size: 5, lifecycle_class: "ephemeral", status: "active",
      provider_region: region, provider_instance_type: itype
    )
  end
  let(:pool_node) { create(:system_node, account: account, node_template: template) }
  let(:member) do
    create(:system_node_instance, :running, node: pool_node, instance_pool_id: pool.id, pool_state: "claimed",
           pool_acquired_at: 2.minutes.ago, provider_region: region, provider_instance_type: itype)
  end

  let(:fleet) { Ai::Tools::SystemFleetTool }
  let(:terminated) { [] }
  let(:perms) { [ "system.instances.control", "system.ci_runner_leases.update", fleet::REQUIRED_PERMISSION ] }
  let(:caller_user) { create(:user, account: account, permissions: perms) }

  before do
    seen = terminated
    allow(::System::ProvisioningService).to receive(:terminate_instance) do |instance:, **|
      seen << instance.id
      double(success?: true, failure?: false, error: nil)
    end
    client = instance_double("Devops::Git::GiteaApiClient", supports_runners?: true)
    allow(client).to receive(:delete_runner).and_return(success: true)
    allow(::Devops::Git::ApiClient).to receive(:for).and_return(client)
  end

  def run(params = {}, user: caller_user, agent: nil, **named)
    tool = fleet.new(account: account, user: user, agent: agent)
    tool.call_origin = "mcp_oauth"
    tool.execute(params: params.merge(named).with_indifferent_access)
  end

  def expect_parked(result)
    expect(result).to include(success: true)
    expect(result[:data]).to include(pending: true)
    operation = Ai::DeferredOperation.find(result[:data][:deferred_operation_id])
    expect(operation.action_category).to eq("system.task.terminate")
    expect(operation.executor_class).to eq("Ai::Executors::DeferredToolCall")
    # *terminate* is in HumanSessionPolicy::DESTRUCTIVE_CATEGORY_PATTERNS
    expect(Ai::ApprovalRequest.find(result[:data][:approval_request_id]).requires_human_session?).to be(true)
    operation
  end

  def approve!(parked)
    request = Ai::ApprovalRequest.find(parked[:data][:approval_request_id])
    Ai::Autonomy::ApprovalWorkflowService.new(account: account)
                                         .approve(request: request, approver: approver,
                                                  origin: Ai::ApprovalDecision::REST_SESSION)
    Ai::DeferredOperation.find(parked[:data][:deferred_operation_id]).reload
  end

  def seed_leased_member
    node = create(:system_node, account: account, node_template: template)
    create(:system_node_instance, node: node, name: "m-#{SecureRandom.hex(3)}", variety: "cloud", status: "running",
           provider_region: region, provider_instance_type: itype, instance_pool_id: pool.id,
           pool_state: "ready", pool_warming_started_at: 1.minute.ago, last_heartbeat_at: Time.current)
  end

  def lease_for(instance, runner_busy: false)
    runner = create(:git_runner, account: account,
                    name: ::System::CiRunnerRegistrationResolver.runner_name(instance))
    runner.update!(status: "busy", busy: true) if runner_busy
    instance.update!(pool_state: "claimed", pool_acquired_at: Time.current)
    ::System::CiRunnerLease.create!(account: account, node_instance: instance, instance_pool: pool,
                                    status: runner_busy ? "busy" : "registered",
                                    runner_name: runner.name, git_runner_id: runner.id)
  end

  # A module_build-style lease: no git_runner_id, tracked by a build Task.
  def build_lease_for(instance, task_status:, status: "registered")
    node = instance.node
    task = create(:system_task, account: account, operable: node, status: task_status)
    instance.update!(pool_state: "claimed", pool_acquired_at: Time.current)
    ::System::CiRunnerLease.create!(account: account, node_instance: instance, instance_pool: pool,
                                    purpose: "module_build", status: status, build_task_id: task.id)
  end

  describe "declarations" do
    %w[system_return_pooled_instance system_release_ci_runner].each do |action|
      it "gates #{action} on system.task.terminate through DeferredToolCall with an ungated_when arm" do
        decl = fleet.declared_action(action)
        expect(decl).to include(mutating: true, action_category: "system.task.terminate",
                                executor_class: "Ai::Executors::DeferredToolCall",
                                gate_context: :deferred_tool_call_context,
                                on_proceed: :deferred_tool_call_result)
        expect(decl[:ungated_when]).to be_present
        expect(decl[:human_only]).to be_falsey
      end
    end
  end

  describe "system_release_ci_runner" do
    let(:instance) { seed_leased_member }

    it "force: true parks, deregistering and terminating nothing" do
      lease = lease_for(instance, runner_busy: true)

      parked = run(action: "system_release_ci_runner", lease_id: lease.id, force: true)

      expect_parked(parked)
      expect(lease.reload.status).to eq("busy")
      expect(terminated).to be_empty
    end

    it "force: true releases on approval, as the original caller" do
      lease = lease_for(instance, runner_busy: true)
      parked = run(action: "system_release_ci_runner", lease_id: lease.id, force: true)

      operation = approve!(parked)

      expect(operation.status).to eq("completed")
      expect(operation.result.with_indifferent_access).not_to include(success: false)
      expect(lease.reload.status).to eq("released")
    end

    it "a plain release of an idle runner is ungated and recycles the member" do
      lease = lease_for(instance)

      result = run(action: "system_release_ci_runner", lease_id: lease.id)

      expect(result).to include(success: true)
      expect(result.dig(:data, :pending)).to be_nil
      expect(result.dig(:data, :ci_runner_lease, :status)).to eq("released")
      expect(Ai::DeferredOperation.count).to eq(0)
      expect(terminated).to eq([ instance.id ])
    end

    it "a plain release of a busy runner is still refused inline, parking nothing" do
      lease = lease_for(instance, runner_busy: true)

      result = run(action: "system_release_ci_runner", lease_id: lease.id)

      expect(result[:success]).to be(false)
      expect(result[:error]).to include("busy")
      expect(Ai::DeferredOperation.count).to eq(0)
    end

    it "force: false is ungated" do
      lease = lease_for(instance)

      result = run(action: "system_release_ci_runner", lease_id: lease.id, force: false)

      expect(result.dig(:data, :pending)).to be_nil
      expect(Ai::DeferredOperation.count).to eq(0)
    end

    it "refuses a caller lacking the tool's permission, parking nothing" do
      lease = lease_for(instance, runner_busy: true)

      denied = run({ action: "system_release_ci_runner", lease_id: lease.id, force: true },
                   user: create(:user, account: account, permissions: [ fleet::REQUIRED_PERMISSION ]))

      expect(denied[:success]).to be(false)
      expect(denied[:error]).to match(/permission denied/)
      expect(Ai::DeferredOperation.count).to eq(0)
    end

    it "force: true on another account's lease is ungated: the handler refuses inline, parking nothing" do
      other = create(:account)
      foreign = ::System::CiRunnerLease.create!(account: other, node_instance: instance, status: "registered")

      result = run(action: "system_release_ci_runner", lease_id: foreign.id, force: true)

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/not found|couldn't find/i)
      expect(Ai::DeferredOperation.count).to eq(0)
      expect(foreign.reload.status).to eq("registered")
      expect(terminated).to be_empty
    end

    it "force: true on an unknown lease id is ungated and answered inline" do
      result = run(action: "system_release_ci_runner", lease_id: SecureRandom.uuid, force: true)

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/not found|couldn't find/i)
      expect(Ai::DeferredOperation.count).to eq(0)
    end

    it "force: true on an already finished lease is ungated and idempotent" do
      lease = ::System::CiRunnerLease.create!(account: account, node_instance: instance, status: "released")

      result = run(action: "system_release_ci_runner", lease_id: lease.id, force: true)

      expect(result).to include(success: true)
      expect(result.dig(:data, :pending)).to be_nil
      expect(Ai::DeferredOperation.count).to eq(0)
      expect(terminated).to be_empty
    end

    it "force given as the string \"true\" parks like force: true, and the approval forces the release" do
      lease = lease_for(instance, runner_busy: true)

      parked = run(action: "system_release_ci_runner", lease_id: lease.id, force: "true")
      expect_parked(parked)
      operation = approve!(parked)

      expect(operation.status).to eq("completed")
      expect(lease.reload.status).to eq("released")
    end

    # M1: the service refuses a non-forced release only when the runner row
    # reads busy. These states reach release! with nothing to refuse them.
    it "parks a non-forced release of a module_build lease (no runner) whose build task is running" do
      lease = build_lease_for(instance, task_status: "running")

      parked = run(action: "system_release_ci_runner", lease_id: lease.id)

      expect_parked(parked)
      expect(lease.reload.status).to eq("registered")
      expect(terminated).to be_empty
    end

    it "does not park a no-runner module_build lease whose build task has finished" do
      lease = build_lease_for(instance, task_status: "complete")

      result = run(action: "system_release_ci_runner", lease_id: lease.id)

      expect(result).to include(success: true)
      expect(result.dig(:data, :pending)).to be_nil
      expect(terminated).to eq([ instance.id ])
    end

    it "parks a non-forced release when the lease status is busy but the runner row reads idle" do
      lease = lease_for(instance)
      lease.update!(status: "busy")

      parked = run(action: "system_release_ci_runner", lease_id: lease.id)

      expect_parked(parked)
      expect(terminated).to be_empty
    end

    it "parks a non-forced release of a lease whose runner row is gone" do
      lease = lease_for(instance)
      Devops::GitRunner.where(id: lease.git_runner_id).delete_all

      parked = run(action: "system_release_ci_runner", lease_id: lease.id)

      expect_parked(parked)
      expect(terminated).to be_empty
    end

    it "parks a non-forced release of a lease already in releasing" do
      lease = lease_for(instance)
      lease.update!(status: "releasing")

      parked = run(action: "system_release_ci_runner", lease_id: lease.id)

      expect_parked(parked)
    end

    it "leaves a freshly leased lease with no runner and no build task ungated" do
      node = create(:system_node, account: account, node_template: template)
      fresh = create(:system_node_instance, node: node, status: "running", variety: "cloud",
                     provider_region: region, provider_instance_type: itype, instance_pool_id: pool.id,
                     pool_state: "claimed", pool_acquired_at: Time.current, last_heartbeat_at: Time.current)
      lease = ::System::CiRunnerLease.create!(account: account, node_instance: fresh, instance_pool: pool,
                                              status: "leased", runner_name: "fresh-runner")

      result = run(action: "system_release_ci_runner", lease_id: lease.id)

      expect(result).to include(success: true)
      expect(result.dig(:data, :pending)).to be_nil
    end
  end

  describe "system_return_pooled_instance" do
    it "a healthy return of a plain claimed member is ungated and recycles it" do
      result = run(action: "system_return_pooled_instance", instance_id: member.id)

      expect(result).to include(success: true)
      expect(result.dig(:data, :pending)).to be_nil
      expect(result.dig(:data, :disposition)).to eq("recycled")
      expect(Ai::DeferredOperation.count).to eq(0)
      expect(terminated).to eq([ member.id ])
    end

    it "parks, terminating nothing, when the member still holds a live CI runner lease" do
      lease_for(member)

      parked = run(action: "system_return_pooled_instance", instance_id: member.id)

      expect_parked(parked)
      expect(member.reload.pool_state).to eq("claimed")
      expect(terminated).to be_empty
    end

    it "recycles the leased member on approval, as the original caller" do
      lease_for(member)
      parked = run(action: "system_return_pooled_instance", instance_id: member.id)

      operation = approve!(parked)

      expect(operation.status).to eq("completed")
      expect(operation.result.with_indifferent_access).not_to include(success: false)
      expect(terminated).to eq([ member.id ])
    end

    # L1: the approval closes the lease through the lease service, so the runner
    # is deregistered and no lease is left pointing at a dead instance.
    it "closes the lease on approval: runner deregistered, lease released, member recycled once" do
      lease = lease_for(member)
      parked = run(action: "system_return_pooled_instance", instance_id: member.id)

      approve!(parked)

      expect(lease.reload.status).to eq("released")
      expect(::Devops::GitRunner.where(id: lease.git_runner_id)).not_to exist if lease.git_runner_id
      expect(member.reload.pool_state).to eq("draining")
      expect(terminated).to eq([ member.id ])
    end

    # L3: parked ON PURPOSE for a reuse_without_reset pool too. Returning a leased
    # member to ready with its runner still registered would hand the next
    # acquirer a builder wired to the prior lease.
    it "parks a leased member's return in a reuse_without_reset pool as well" do
      pool.update!(metadata: { "reuse_without_reset" => true })
      lease_for(member)

      parked = run(action: "system_return_pooled_instance", instance_id: member.id)

      expect_parked(parked)
      expect(member.reload.pool_state).to eq("claimed")
    end

    # S3: the lease was released (ungated, idle) while the return sat parked.
    it "refuses the replay, recycling nothing twice, when the lease was released while parked" do
      lease = lease_for(member)
      parked = run(action: "system_return_pooled_instance", instance_id: member.id)
      run(action: "system_release_ci_runner", lease_id: lease.id)
      expect(terminated).to eq([ member.id ])

      operation = approve!(parked)

      replayed = operation.result.with_indifferent_access
      expect(replayed).to include(success: false)
      expect(replayed[:error]).to include("can only return 'claimed'")
      expect(member.reload.pool_state).to eq("draining")
      expect(terminated).to eq([ member.id ])
    end

    it "treats a finished lease as healthy: ungated" do
      ::System::CiRunnerLease.create!(account: account, node_instance: member, status: "released")

      result = run(action: "system_return_pooled_instance", instance_id: member.id)

      expect(result.dig(:data, :pending)).to be_nil
      expect(Ai::DeferredOperation.count).to eq(0)
    end

    it "leaves a malformed call (unknown instance) to the handler's own refusal, parking nothing" do
      result = run(action: "system_return_pooled_instance", instance_id: SecureRandom.uuid)

      expect(result[:success]).to be(false)
      expect(Ai::DeferredOperation.count).to eq(0)
    end

    it "refuses a caller lacking system.instances.control, parking nothing" do
      lease_for(member)

      denied = run({ action: "system_return_pooled_instance", instance_id: member.id },
                   user: create(:user, account: account, permissions: [ fleet::REQUIRED_PERMISSION ]))

      expect(denied[:success]).to be(false)
      expect(denied[:error]).to match(/permission denied: system\.instances\.control/)
      expect(Ai::DeferredOperation.count).to eq(0)
    end

    it "refuses an agent principal with no user, parking nothing" do
      lease_for(member)

      denied = run({ action: "system_return_pooled_instance", instance_id: member.id },
                   user: nil, agent: create(:ai_agent, account: account))

      expect(denied[:success]).to be(false)
      expect(denied[:error]).to be_present
      expect(denied[:error]).not_to match(/pending/i)
      expect(Ai::DeferredOperation.count).to eq(0)
      expect(terminated).to be_empty
    end
  end
end
