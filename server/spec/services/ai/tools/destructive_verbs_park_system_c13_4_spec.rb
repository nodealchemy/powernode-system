# frozen_string_literal: true

require "rails_helper"

# c13-4 (operator ruling, 2026-10-24): system_return_pooled_instance and
# system_release_ci_runner gate the terminating path through
# Ai::Executors::DeferredToolCall, under the existing system.task.terminate
# category.
#
#   system_release_ci_runner      ALLOWLIST, fail closed: ungated only when force
#                                 is not true AND the lease's work is provably
#                                 finished (CiRunnerLeaseSweepService#work_finished?:
#                                 a terminal build task for module_build; a
#                                 fetched, terminal workflow run for generic and
#                                 disk_image_build, plus publish confirmation for
#                                 the latter). No consumer signal, a failed run
#                                 fetch or any other purpose parks. An unknown or
#                                 finished lease, or a releasing lease whose member
#                                 is no longer claimed, is answered inline.
#   system_return_pooled_instance a member that still holds a live CI runner lease
#                                 parks (returning it terminates the VM under the
#                                 lease). A call the handler would refuse anyway
#                                 (not a pool member, not claimed) is answered inline.
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

  # A generic lease correlated to a runner. With run: true it also carries a
  # workflow run reference (the consumer signal the gate reads via the sweep's
  # run fetch, stubbed by stub_run).
  def lease_for(instance, runner_busy: false, run: false, purpose: "generic")
    runner = create(:git_runner, account: account,
                    name: ::System::CiRunnerRegistrationResolver.runner_name(instance))
    runner.update!(status: "busy", busy: true) if runner_busy
    instance.update!(pool_state: "claimed", pool_acquired_at: Time.current)
    attrs = run ? { workflow_run_id: "42", workflow_run_repo: "acme/repo" } : {}
    ::System::CiRunnerLease.create!(account: account, node_instance: instance, instance_pool: pool,
                                    purpose: purpose, status: runner_busy ? "busy" : "registered",
                                    runner_name: runner.name, git_runner_id: runner.id, **attrs)
  end

  # What CiRunnerLeaseSweepService#fetch_run answers: a run hash, or nil (a failed fetch).
  def stub_run(status: "completed", conclusion: "success")
    run = status && { status: status, conclusion: conclusion }
    allow_any_instance_of(::System::CiRunnerLeaseSweepService).to receive(:fetch_run).and_return(run)
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

    def release(lease, **extra) = run(action: "system_release_ci_runner", lease_id: lease.id, **extra)

    def expect_released_inline(result, lease)
      expect(result).to include(success: true)
      expect(result.dig(:data, :pending)).to be_nil
      expect(Ai::DeferredOperation.count).to eq(0)
      expect(lease.reload.status).to eq("released")
    end

    it "force: true parks, deregistering and terminating nothing" do
      lease = lease_for(instance, runner_busy: true)

      expect_parked(release(lease, force: true))
      expect(lease.reload.status).to eq("busy")
      expect(terminated).to be_empty
    end

    it "force: true releases on approval, as the original caller" do
      lease = lease_for(instance, runner_busy: true)
      parked = release(lease, force: true)

      operation = approve!(parked)

      expect(operation.status).to eq("completed")
      expect(operation.result.with_indifferent_access).not_to include(success: false)
      expect(lease.reload.status).to eq("released")
    end

    it "force given as the string \"true\" parks like force: true, and the approval forces the release" do
      lease = lease_for(instance, runner_busy: true)

      parked = release(lease, force: "true")
      expect_parked(parked)
      operation = approve!(parked)

      expect(operation.status).to eq("completed")
      expect(lease.reload.status).to eq("released")
    end

    it "force: true parks even when the work is provably finished" do
      stub_run
      lease = lease_for(instance, run: true)

      expect_parked(release(lease, force: true))
      expect(terminated).to be_empty
    end

    describe "ungated: the lease's work is provably finished" do
      it "generic lease whose workflow run is terminal" do
        stub_run(status: "completed")
        lease = lease_for(instance, run: true)

        result = release(lease)

        expect_released_inline(result, lease)
        expect(terminated).to eq([ instance.id ])
      end

      it "force: false is ungated the same way" do
        stub_run(status: "failed", conclusion: "failure")
        lease = lease_for(instance, run: true)

        expect_released_inline(release(lease, force: false), lease)
      end

      it "module_build lease whose build task is in a terminal state" do
        lease = build_lease_for(instance, task_status: "complete")

        result = release(lease)

        expect_released_inline(result, lease)
        expect(terminated).to eq([ instance.id ])
      end

      it "disk_image_build lease whose run is terminal and whose publication arrived" do
        stub_run(status: "completed", conclusion: "success")
        lease = lease_for(instance, run: true, purpose: "disk_image_build")
        lease.update!(leased_at: 1.hour.ago)
        allow_any_instance_of(::System::CiRunnerLeaseSweepService).to receive(:publish_arrived?).and_return(true)

        expect_released_inline(release(lease), lease)
      end

      it "an unknown lease id is answered inline, parking nothing" do
        result = run(action: "system_release_ci_runner", lease_id: SecureRandom.uuid, force: true)

        expect(result[:success]).to be(false)
        expect(result[:error]).to match(/not found/i)
        expect(Ai::DeferredOperation.count).to eq(0)
      end

      it "another account's lease is answered inline, parking nothing" do
        foreign = ::System::CiRunnerLease.create!(account: create(:account), node_instance: instance, status: "registered")

        result = release(foreign, force: true)

        expect(result[:success]).to be(false)
        expect(result[:error]).to match(/not found/i)
        expect(Ai::DeferredOperation.count).to eq(0)
        expect(foreign.reload.status).to eq("registered")
        expect(terminated).to be_empty
      end

      it "an already finished lease is idempotent, even with force" do
        lease = ::System::CiRunnerLease.create!(account: account, node_instance: instance, status: "released")

        result = release(lease, force: true)

        expect(result).to include(success: true)
        expect(result.dig(:data, :pending)).to be_nil
        expect(Ai::DeferredOperation.count).to eq(0)
        expect(terminated).to be_empty
      end

      it "a releasing lease whose member is no longer claimed (the handler has nothing left to tear down)" do
        lease = lease_for(instance)
        lease.update!(status: "releasing")
        instance.update!(pool_state: "draining")

        result = release(lease)

        expect(result.dig(:data, :pending)).to be_nil
        expect(Ai::DeferredOperation.count).to eq(0)
        expect(terminated).to be_empty
      end
    end

    describe "parks: the work is not provably finished (fail closed)" do
      it "M-1a: a generic lease still `leased` with no runner and no consumer signal" do
        fresh = ::System::CiRunnerLease.create!(account: account, node_instance: seed_claimed(instance), instance_pool: pool,
                                                status: "leased", runner_name: "fresh-runner")

        expect_parked(release(fresh))
        expect(fresh.reload.status).to eq("leased")
        expect(terminated).to be_empty
      end

      it "a registered lease with an idle runner but no consumer signal at all" do
        lease = lease_for(instance)

        expect_parked(release(lease))
        expect(terminated).to be_empty
      end

      it "M-1b: a registered lease whose workflow run is still in progress (sweep has not marked it busy)" do
        stub_run(status: "in_progress", conclusion: nil)
        lease = lease_for(instance, run: true)

        expect_parked(release(lease))
        expect(terminated).to be_empty
      end

      it "a run fetch failure" do
        stub_run(status: nil)
        lease = lease_for(instance, run: true)

        expect_parked(release(lease))
        expect(terminated).to be_empty
      end

      it "a busy runner without force (no time-of-check gap: it parks rather than being refused inline)" do
        stub_run(status: "in_progress", conclusion: nil)
        lease = lease_for(instance, run: true, runner_busy: true)

        parked = release(lease)
        expect_parked(parked)

        # The approval does not force: the lease service still refuses the busy runner.
        operation = approve!(parked)
        expect(operation.result.with_indifferent_access).to include(success: false)
        expect(operation.result.with_indifferent_access[:error]).to include("busy")
        expect(lease.reload.status).to eq("busy")
        expect(terminated).to be_empty
      end

      it "a lease status of busy with no consumer signal" do
        lease = lease_for(instance)
        lease.update!(status: "busy")

        expect_parked(release(lease))
      end

      it "a lease already in releasing whose member is still claimed" do
        lease = lease_for(instance)
        lease.update!(status: "releasing")

        expect_parked(release(lease))
      end

      it "a module_build lease whose build task is running" do
        lease = build_lease_for(instance, task_status: "running")

        expect_parked(release(lease))
        expect(lease.reload.status).to eq("registered")
        expect(terminated).to be_empty
      end

      it "a module_build lease whose build task is pending" do
        expect_parked(release(build_lease_for(instance, task_status: "pending")))
      end

      it "L-4: a module_build lease whose build task row is missing" do
        lease = build_lease_for(instance, task_status: "complete")
        ::System::Task.where(id: lease.build_task_id).delete_all

        expect_parked(release(lease))
      end

      it "a module_build lease with no build task id" do
        lease = lease_for(instance, purpose: "module_build")

        expect_parked(release(lease))
      end

      it "L-2: a disk_image_build lease whose run succeeded but whose publication has not arrived" do
        stub_run(status: "completed", conclusion: "success")
        lease = lease_for(instance, run: true, purpose: "disk_image_build")
        lease.update!(leased_at: 1.hour.ago)

        expect_parked(release(lease))
        expect(terminated).to be_empty
      end

      it "a lint_discovery lease (the platform's own, no operator consumer signal)" do
        stub_run
        lease = lease_for(instance, run: true, purpose: "lint_discovery")

        expect_parked(release(lease))
      end
    end

    it "refuses a caller lacking the tool's permission, parking nothing" do
      lease = lease_for(instance, runner_busy: true)

      denied = run({ action: "system_release_ci_runner", lease_id: lease.id, force: true },
                   user: create(:user, account: account, permissions: [ fleet::REQUIRED_PERMISSION ]))

      expect(denied[:success]).to be(false)
      expect(denied[:error]).to match(/permission denied/)
      expect(Ai::DeferredOperation.count).to eq(0)
    end

    def seed_claimed(inst)
      inst.update!(pool_state: "claimed", pool_acquired_at: Time.current)
      inst
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
      expect(::Devops::GitRunner.where(id: lease.git_runner_id)).not_to exist
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

    # L-5: in a reuse_without_reset pool the approved return deregisters the runner
    # first (lease released), then the member goes back to ready: no terminate.
    it "reuses a leased member in a reuse_without_reset pool on approval: runner deregistered, no terminate" do
      pool.update!(metadata: { "reuse_without_reset" => true })
      lease = lease_for(member)
      parked = run(action: "system_return_pooled_instance", instance_id: member.id)

      operation = approve!(parked)

      result = operation.result.with_indifferent_access
      expect(operation.status).to eq("completed")
      expect(result).not_to include(success: false)
      expect(result.dig(:data, :disposition)).to eq("reused")
      expect(lease.reload.status).to eq("released")
      expect(::Devops::GitRunner.where(id: lease.git_runner_id)).not_to exist
      expect(member.reload.pool_state).to eq("ready")
      expect(terminated).to be_empty
    end

    # L-1: a recycle pool says "recycled" even when the member is cordoned; the
    # label "cordoned" belongs to the reuse path only.
    it "labels a cordoned leased member in a recycle pool \"recycled\"" do
      allow_any_instance_of(::System::NodeInstance).to receive(:cordoned?).and_return(true)
      lease_for(member)
      parked = run(action: "system_return_pooled_instance", instance_id: member.id)

      operation = approve!(parked)

      expect(operation.result.with_indifferent_access.dig(:data, :disposition)).to eq("recycled")
      expect(terminated).to eq([ member.id ])
    end

    it "answers inline, parking nothing, for a member that is not claimed even with a live lease" do
      lease_for(member)
      member.update!(pool_state: "draining")

      result = run(action: "system_return_pooled_instance", instance_id: member.id)

      expect(result[:success]).to be(false)
      expect(result[:error]).to include("can only return 'claimed'")
      expect(Ai::DeferredOperation.count).to eq(0)
    end

    # S3: the lease was released (ungated, idle) while the return sat parked.
    it "refuses the replay, recycling nothing twice, when the lease was released while parked" do
      lease = lease_for(member, run: true)
      parked = run(action: "system_return_pooled_instance", instance_id: member.id)
      stub_run # the run finished meanwhile, so the release needs no approval
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
