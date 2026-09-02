# frozen_string_literal: true

require "rails_helper"

# IMP-8c0f0fe9a8cf (APO-3b). Both mutating branches of this skill used to be
# decoys: `scale` wrote target_replicas and nothing reconciled it, and
# `drain_instance` wrote config markers nothing read while telling the caller so
# in its own recommendations. This spec pins the replacements — a real cordon +
# stop for drain, and a real reconcile for scale — plus the refusal that keeps
# the control plane away from its own hosting stack.
RSpec.describe System::Ai::Skills::PlatformResilienceExecutor do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:exec)     { described_class.new(account: account) }

  describe ".descriptor" do
    it "no longer advertises the drain timeout it never enforced" do
      expect(described_class.descriptor[:inputs]).not_to have_key(:timeout_seconds)
    end
  end

  describe "drain_instance" do
    let(:instance) { create(:system_node_instance, node: node, account: account, status: "running") }

    it "actually stops the instance through the lifecycle choke point" do
      expect(::System::InstanceControlService).to receive(:execute)
        .with(instance: an_object_having_attributes(id: instance.id), action: :stop)
        .and_return(::System::Runtime::Result.ok(data: { status: "stopped" }))

      result = exec.execute(action: "drain_instance", instance_id: instance.id)

      expect(result[:success]).to be true
      expect(result.dig(:data, :data, :stopped)).to be true
      expect(result.dig(:data, :recommendations).join(" ")).not_to match(/Nothing reads these markers/)
    end

    it "cordons a pool member so the allocator stops handing it out" do
      pool = ::System::InstancePool.create!(
        account: account, node_template: template, name: "drain-pool",
        target_size: 1, min_size: 0, max_size: 2, lifecycle_class: "ephemeral"
      )
      instance.update!(instance_pool_id: pool.id, pool_state: "ready")
      allow(::System::InstanceControlService).to receive(:execute)
        .and_return(::System::Runtime::Result.ok(data: { status: "stopped" }))

      result = exec.execute(action: "drain_instance", instance_id: instance.id)

      expect(instance.reload.pool_state).to eq("draining")
      expect(result.dig(:data, :data, :cordoned)).to be true
    end

    it "surfaces a refused stop as a failure instead of claiming a drain" do
      allow(::System::InstanceControlService).to receive(:execute)
        .and_return(::System::Runtime::Result.err(error: "instance is under an operator ops hold"))

      result = exec.execute(action: "drain_instance", instance_id: instance.id)

      expect(result[:success]).to be false
      expect(result[:error]).to match(/ops hold/)
    end

    it "refuses to drain this control plane's own hosting node" do
      SiteSetting.set("self_hosting_node_id", node.id)
      expect(::System::InstanceControlService).not_to receive(:execute)

      result = exec.execute(action: "drain_instance", instance_id: instance.id)

      expect(result[:success]).to be false
      expect(result[:error]).to match(/own hosting|self-management/i)
    end

    # IMP-8c0f0fe9a8cf: emit_event! passed severity "info", which is not in
    # System::FleetEvent::SEVERITIES, so every create! raised into the rescue
    # and this skill emitted NOTHING while its class comment said it did.
    it "emits a drain_started FleetEvent that actually persists" do
      allow(::System::InstanceControlService).to receive(:execute)
        .and_return(::System::Runtime::Result.ok(data: { status: "stopped" }))

      expect {
        exec.execute(action: "drain_instance", instance_id: instance.id)
      }.to change { ::System::FleetEvent.where(kind: "platform.resilience.drain_started").count }.by(1)
    end

    it "no longer writes the drain_* config markers nothing reads" do
      allow(::System::InstanceControlService).to receive(:execute)
        .and_return(::System::Runtime::Result.ok(data: { status: "stopped" }))

      exec.execute(action: "drain_instance", instance_id: instance.id)

      expect(instance.reload.config.keys).not_to include("drain_initiated_at")
    end
  end

  # REVIEW FINDING: a boolean cordon collapsed "nothing to cordon" and "the
  # cordon blew up" into one false, which the caller rendered as the CLAIM
  # "it is not a pool member" — while stopping the instance anyway and leaving
  # the allocator calling it ready.
  describe "drain_instance — cordon states" do
    let(:pool) do
      ::System::InstancePool.create!(
        account: account, node_template: template, name: "drain-pool",
        target_size: 1, min_size: 0, max_size: 2, lifecycle_class: "ephemeral"
      )
    end
    let(:instance) { create(:system_node_instance, node: node, account: account, status: "running") }

    it "refuses the drain when a real pool member's cordon write raises" do
      instance.update!(instance_pool_id: pool.id, pool_state: "ready")
      allow_any_instance_of(::System::NodeInstance).to receive(:update!)
        .and_raise(ActiveRecord::RecordInvalid.new(instance))
      expect(::System::InstanceControlService).not_to receive(:execute)

      result = exec.execute(action: "drain_instance", instance_id: instance.id)

      expect(result[:success]).to be false
      expect(result[:error]).to match(/cordon step/i)
      expect(result[:error]).not_to match(/not a pool member/i)
    end

    # Both release paths guard on pool_state == "claimed"
    # (system_fleet_tool#return_pooled_instance, AgentFleetMissionService#
    # reap_member!), so flipping a claimed member to "draining" strands it
    # permanently — and it was already un-acquirable, so the flip buys nothing.
    it "does NOT flip a CLAIMED member to draining" do
      instance.update!(instance_pool_id: pool.id, pool_state: "claimed",
                       pool_acquired_at: Time.current)
      allow(::System::InstanceControlService).to receive(:execute)
        .and_return(::System::Runtime::Result.ok(data: { status: "stopped" }))

      result = exec.execute(action: "drain_instance", instance_id: instance.id)

      expect(result[:success]).to be true
      expect(instance.reload.pool_state).to eq("claimed")
      expect(result.dig(:data, :data, :cordon_state)).to eq(:claimed)
      expect(result.dig(:data, :recommendations).join(" ")).to match(/CLAIMED/)
    end
  end

  # REVIEW FINDING: this branch now stops a fleet node through the same choke
  # point system_stop_instance uses, but the MCP door onto the skill maps only
  # to system.platform.scale.
  describe "drain_instance — actuation permission" do
    let(:instance) { create(:system_node_instance, node: node, account: account, status: "running") }

    it "refuses a user holding only the skill's own system.platform.scale grant" do
      operator = create(:user, account: account,
                               permissions: %w[system.platform.read system.platform.scale])
      expect(::System::InstanceControlService).not_to receive(:execute)

      result = described_class.new(account: account, user: operator)
                              .execute(action: "drain_instance", instance_id: instance.id)

      expect(result[:success]).to be false
      expect(result[:error]).to match(/system\.instances\.control/)
    end

    it "allows a user holding system.instances.control" do
      operator = create(:user, account: account,
                               permissions: %w[system.platform.scale system.instances.control])
      allow(::System::InstanceControlService).to receive(:execute)
        .and_return(::System::Runtime::Result.ok(data: { status: "stopped" }))

      result = described_class.new(account: account, user: operator)
                              .execute(action: "drain_instance", instance_id: instance.id)

      expect(result[:success]).to be true
    end
  end

  describe "scale" do
    let(:deployment) do
      create(:system_platform_deployment, account: account, node_template: template, target_replicas: 1)
    end

    it "refuses a hub deployment without writing target_replicas" do
      node
      SiteSetting.set("self_hosting_node_id", node.id)

      result = exec.execute(action: "scale", deployment_id: deployment.id, direction: "increment")

      expect(result[:success]).to be false
      expect(result[:error]).to match(/own hosting stack|self-remediat/i)
      expect(deployment.reload.target_replicas).to eq(1)
    end

    it "reconciles the deployment after recording the new target" do
      node
      recon = instance_double(
        ::System::Platform::ReplicaReconciler,
        hub_deployment?: false,
        reconcile!: ::System::Platform::ReplicaReconciler::Result.new(
          ok: true, deployment_id: deployment.id, target_replicas: 2,
          actual_before: 1, actual_after: 2, provisioned_instance_ids: %w[abc],
          terminated_instance_ids: [], pending_removal_instance_ids: [], failures: [],
          message: "provisioned 1"
        )
      )
      allow(::System::Platform::ReplicaReconciler).to receive(:new).and_return(recon)
      expect(recon).to receive(:reconcile!)

      result = exec.execute(action: "scale", deployment_id: deployment.id, direction: "increment")

      expect(result[:success]).to be true
      expect(deployment.reload.target_replicas).to eq(2)
      expect(result.dig(:data, :data, :reconciled, :provisioned_instance_ids)).to eq(%w[abc])
      expect(result.dig(:data, :recommendations).join(" ")).not_to match(/queued for a follow-up slice/)
    end

    # REVIEW FINDING (blocker). An earlier revision short-circuited to "already
    # at the requested replica count" whenever the requested target equalled
    # the stored one — the state EVERY deployment whose target was last written
    # by the Scaling panel or the GitOps bridge is already in, and the state a
    # clamped pass leaves behind. It reported a matching COLUMN as a matching
    # FLEET and skipped the actuator: this task's defect, one layer up.
    it "still reconciles when the requested target equals the stored one" do
      node
      deployment.update!(target_replicas: 3)
      recon = instance_double(::System::Platform::ReplicaReconciler, hub_deployment?: false)
      allow(::System::Platform::ReplicaReconciler).to receive(:new).and_return(recon)
      expect(recon).to receive(:reconcile!).and_return(
        ::System::Platform::ReplicaReconciler::Result.new(
          ok: true, deployment_id: deployment.id, target_replicas: 3,
          actual_before: 1, actual_after: 3, provisioned_instance_ids: %w[a b],
          terminated_instance_ids: [], pending_removal_instance_ids: [], failures: [],
          message: "Provisioned 2 of 2 requested replica(s)."
        )
      )

      result = exec.execute(action: "scale", deployment_id: deployment.id,
                            direction: "set", target_replicas: 3)

      expect(result[:success]).to be true
      expect(result.dig(:data, :data, :reconciled, :provisioned_instance_ids)).to eq(%w[a b])
    end

    # REVIEW FINDING: `success:` is the documented stop signal
    # (SkillCompositionRunner halts a composition on success == false), so a
    # refused reconcile reported as success tells a runner that a scale which
    # provisioned nothing worked — with target_replicas already moved.
    it "returns FAILURE when the reconcile refuses for a non-hub reason" do
      node
      recon = instance_double(::System::Platform::ReplicaReconciler, hub_deployment?: false)
      allow(::System::Platform::ReplicaReconciler).to receive(:new).and_return(recon)
      allow(recon).to receive(:reconcile!).and_return(
        ::System::Platform::ReplicaReconciler::Result.new(
          ok: false, refused_reason: :no_provisioning_node, deployment_id: deployment.id,
          target_replicas: 2, actual_before: 0, actual_after: 0,
          provisioned_instance_ids: [], terminated_instance_ids: [],
          pending_removal_instance_ids: [], failures: [],
          message: "Cannot scale out: no System::Node in this account carries the template."
        )
      )

      result = exec.execute(action: "scale", deployment_id: deployment.id, direction: "increment")

      expect(result[:success]).to be false
      expect(result[:error]).to match(/no System::Node/)
      expect(result.dig(:data, :reconciled, :refused_reason)).to eq(:no_provisioning_node)
    end

    # The reconciler checks system.instances.create / .control and must be able
    # to tell a trusted in-process caller from an MCP instance principal, which
    # also arrives with no User.
    it "hands the reconciler this executor's own internal-caller answer" do
      node
      expect(::System::Platform::ReplicaReconciler).to receive(:new)
        .with(hash_including(internal: true))
        .and_return(instance_double(::System::Platform::ReplicaReconciler,
                                    hub_deployment?: true))

      exec.execute(action: "scale", deployment_id: deployment.id, direction: "increment")
    end
  end
end
