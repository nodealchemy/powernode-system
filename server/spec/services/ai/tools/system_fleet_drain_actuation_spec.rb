# frozen_string_literal: true

require "rails_helper"

# IMP-f4fe1ed1ec1e (APO-3b remainder).
#
# APO-3b made System::Ai::Skills::PlatformResilienceExecutor#drain_instance a
# REAL drain — cordon the pool member, then stop the instance through
# System::InstanceControlService — and dropped the `timeout_seconds` knob no
# code ever enforced. Its finalizer was barred from app/services/ai/tools, so
# the MCP door onto the same capability was left behind: `system_drain_instance`
# still merged `drain_initiated_at` / `drain_timeout_seconds` into the
# instance's config, emitted an event, and stopped nothing. Two doors onto one
# verb, one of them a decoy.
#
# This spec pins the equivalence: the MCP verb actuates through the SAME path,
# and the tool no longer advertises a timeout it cannot honour.
RSpec.describe Ai::Tools::SystemFleetTool, "system_drain_instance actuation" do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template, name: "drain-node") }
  let(:instance) { create(:system_node_instance, :running, node: node, account: account) }
  let(:tool)     { described_class.new(account: account, internal: true) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  def stub_stop_ok!
    allow(::System::InstanceControlService).to receive(:execute)
      .and_return(::System::Runtime::Result.ok(data: { status: "stopped" }))
  end

  describe "actuation" do
    it "stops the instance through the lifecycle choke point" do
      expect(::System::InstanceControlService).to receive(:execute)
        .with(instance: an_object_having_attributes(id: instance.id), action: :stop)
        .and_return(::System::Runtime::Result.ok(data: { status: "stopped" }))

      r = call("system_drain_instance", instance_id: instance.id)

      expect(r[:success]).to be true
      expect(r.dig(:data, :stopped)).to be true
    end

    it "cordons a ready pool member out of the allocator" do
      pool = ::System::InstancePool.create!(
        account: account, node_template: template, name: "mcp-drain-pool",
        target_size: 1, min_size: 0, max_size: 2, lifecycle_class: "ephemeral"
      )
      instance.update!(instance_pool_id: pool.id, pool_state: "ready")
      stub_stop_ok!

      r = call("system_drain_instance", instance_id: instance.id)

      expect(r[:success]).to be true
      expect(instance.reload.pool_state).to eq("draining")
      expect(r.dig(:data, :cordoned)).to be true
    end

    it "writes no inert drain_* markers onto the instance config" do
      stub_stop_ok!

      call("system_drain_instance", instance_id: instance.id)

      expect(instance.reload.config.keys)
        .not_to include("drain_initiated_at", "drain_timeout_seconds")
    end

    it "returns a refused stop as an error instead of claiming a drain" do
      allow(::System::InstanceControlService).to receive(:execute)
        .and_return(::System::Runtime::Result.err(error: "instance is under an operator ops hold"))

      r = call("system_drain_instance", instance_id: instance.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/ops hold/)
    end

    it "still scopes to the caller's account" do
      other_node = create(:system_node, account: create(:account), name: "other-drain")
      other = create(:system_node_instance, :running, node: other_node)

      r = call("system_drain_instance", instance_id: other.id)

      expect(r[:success]).to be false
    end

    # REVIEW FINDING (major). BaseSkillExecutor#pending_result answers
    # {success: true, pending: true, data: <payload with NO :data sub-key>}.
    # Flattening that would drop `pending` and the approval id and answer
    # `drained: true` for an operation that ran nothing — the false-success
    # shape this rewrite exists to remove, and a shape the sibling
    # system_platform_resilience wrapper already forwards intact. The guard is
    # on the SHAPE, so it holds the day PlatformResilienceExecutor declares
    # requires_approval (it does not today; this verb now stops a fleet node,
    # which is the kind of action that later gets gated).
    it "passes a PENDING approval envelope through instead of claiming a drain" do
      pending_payload = {
        pending: true,
        action_category: "platform.resilience",
        deferred_operation_id: "def-1",
        approval_request_id: "apr-1",
        message: "Approval required: platform.resilience"
      }
      allow_any_instance_of(::System::Ai::Skills::PlatformResilienceExecutor)
        .to receive(:execute)
        .and_return({ success: true, pending: true, data: pending_payload })

      r = call("system_drain_instance", instance_id: instance.id)

      expect(r[:success]).to be true
      expect(r[:data]).to eq(pending_payload)
      expect(r[:data]).not_to have_key(:drained)
    end
  end

  # REVIEW FINDING (minor). Every assertion above builds the tool with
  # `internal: true`, which makes the executor's system.instances.control
  # re-check a no-op (build_skill_executor forwards no user, so the executor
  # sees user: nil + not instance-authorized => internal_caller?). These two
  # drive the same verbs through a REAL user so the guard is pinned through
  # the MCP door rather than assumed.
  describe "permission, through a real operator" do
    let(:scaler) do
      create(:user, account: account, permissions: %w[system.platform.scale system.instances.read])
    end
    let(:scaler_tool) { described_class.new(account: account, user: scaler) }

    it "refuses system_drain_instance to a caller holding only system.platform.scale" do
      expect(::System::InstanceControlService).not_to receive(:execute)

      r = scaler_tool.execute(params: { action: "system_drain_instance", instance_id: instance.id })

      expect(r[:success]).to be false
      expect(r[:error]).to match(/system\.instances\.control|permission/i)
    end

    # The wrapper's OWN permission entry is system.platform.scale, so this
    # call clears the tool gate and is refused one layer down, by the
    # executor's check on the PRIMITIVE it now performs.
    it "refuses the platform_resilience drain op at the executor's control-permission check" do
      expect(::System::InstanceControlService).not_to receive(:execute)

      r = scaler_tool.execute(
        params: { action: "system_platform_resilience", op: "drain_instance", instance_id: instance.id }
      )

      expect(r[:success]).to be false
      expect(r[:error]).to match(/system\.instances\.control/)
    end
  end

  describe "action definitions" do
    let(:defs) { described_class.action_definitions }

    it "no longer advertises the drain timeout the executor dropped" do
      expect(defs.fetch("system_drain_instance")[:parameters]).not_to have_key(:timeout_seconds)
    end

    it "no longer advertises timeout_seconds on the resilience wrapper either" do
      expect(defs.fetch("system_platform_resilience")[:parameters]).not_to have_key(:timeout_seconds)
    end

    it "describes the verb as a cordon+stop, not a marker write" do
      description = defs.fetch("system_drain_instance")[:description]
      expect(description).not_to match(/Workloads remain running|records drain intent|drain_initiated_at/)
      expect(description).to match(/stop/i)
    end
  end
end
