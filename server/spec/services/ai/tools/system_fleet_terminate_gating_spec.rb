# frozen_string_literal: true

require "rails_helper"

# IMP-d410a587d6bf — `system_terminate_instance` over MCP went straight to
# System::ProvisioningService and destroyed the VM, while the REST twin for the
# same operation (System::NodeInstanceGating#gate_or_execute) honoured the
# seeded `system.task.terminate` => require_approval policy and parked an
# ApprovalRequest instead. SystemFleetTool held ZERO Ai::AutonomyGate
# references, and nothing gated downstream (ProvisioningService,
# InstanceControlService) or upstream (the MCP dispatch).
#
# THE ORACLE ASSERTS THE ROW, not the response shape. This repo has shipped a
# guard that rendered a refusal from an action body while the write landed, so
# a `pending`-shaped response proves nothing on its own.
#
# The provider adapter is stubbed at System::Providers::Registry — NOT at
# ProvisioningService — and that stub is load-bearing in both directions:
# ungate this action and the real ProvisioningService#terminate_instance runs
# through to #finalize_termination!, so the instance row genuinely reaches
# "terminated". That is what makes "not terminated" a discriminating assertion
# rather than one that holds either way, and it is also what lets the approval
# and auto_approve examples prove the termination really happens.
#
# THE PRINCIPAL IS A USER. Mcp::Principal::DESTRUCTIVE_TOOL_PATTERNS already
# refuses *terminate*/*destroy* for INSTANCE principals unconditionally, so an
# instance-principal example passes whether or not this gate works — a
# redundant guard corrupting the oracle. Nothing here touches that overlay.
RSpec.describe "SystemFleetTool terminate approval gating (IMP-d410a587d6bf)" do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account, permissions: %w[system.instances.control]) }
  let(:tool)     { Ai::Tools::SystemFleetTool.new(account: account, user: user) }
  let(:instance) { create(:system_node_instance, :running, account: account) }

  let(:adapter) { double("provider_adapter") }

  before do
    allow(::System::Providers::Registry).to receive(:for_instance).and_return(adapter)
    allow(adapter).to receive(:terminate_instance).and_return({ success: true })
  end

  def terminate!
    tool.execute(params: { action: "system_terminate_instance", instance_id: instance.id })
  end

  # The declaration carries a literal category so class-body evaluation does
  # not force an executor autoload; these keep the literal honest.
  #
  # Pinning it to the executor constant ALONE would not: both halves of a typo
  # move together, and Ai::InterventionPolicyService's default is
  # require_approval for EVERY category, so a misspelled category still parks
  # and every other example in this file still passes. The load-bearing claim
  # of the design is that ONE operator-tuned row governs terminate on both
  # surfaces, so the category is pinned to the SEEDED declaration.
  describe "the declared category" do
    let(:declaration) { Ai::Tools::SystemFleetTool.declared_action("system_terminate_instance") }

    it "is the one the executor names" do
      expect(declaration[:action_category])
        .to eq(::System::Executors::TerminateInstance::ACTION_CATEGORY)
      expect(declaration[:executor_class]).to eq("System::Executors::TerminateInstance")
    end

    it "is a category the platform actually seeds, at require_approval" do
      seeded = ::System::Governance::PolicyDeclarations::MANUAL_OPERATION_POLICIES

      expect(seeded).to include(declaration[:action_category])
      expect(seeded[declaration[:action_category]]).to eq("require_approval")
    end

    # The REST twin gates the same operation on "system.task.#{event}" — this
    # is the half that proves both surfaces resolve the SAME row.
    it "is the category the REST twin resolves for terminate" do
      expect(declaration[:action_category]).to eq("system.task.terminate")
    end
  end

  describe "a policy row for the declared category actually binds this tool" do
    # Proves the wiring end-to-end rather than by name: a real `block` row on
    # the declared category must refuse the MCP call. If the declaration named
    # a category nothing seeds, this row would not match and the action would
    # park instead of blocking.
    before do
      ::Ai::InterventionPolicy.create!(
        account: account,
        action_category: "system.task.terminate",
        scope: "global", ai_agent_id: nil, user_id: nil,
        policy: "block", priority: 5, is_active: true,
        conditions: {}, preferred_channels: %w[notification]
      )
    end

    it "blocks, terminates nothing, and reports the refusal" do
      response = terminate!

      expect(instance.reload.status).not_to eq("terminated")
      expect(adapter).not_to have_received(:terminate_instance)
      expect(response[:success]).to be(false)
      expect(response[:error]).to be_present
    end
  end

  describe "the seeded require_approval tier (default resolution)" do
    # No policy row is seeded in a spec account, and
    # Ai::InterventionPolicyService's default is require_approval — the same
    # tier `system.task.terminate` is declared at in
    # System::Governance::PolicyDeclarations::MANUAL_OPERATION_POLICIES.
    it "parks an approval and leaves the instance NOT terminated" do
      response = terminate!

      # 1. The ROW, and the provider. Ungate this action and both flip.
      expect(instance.reload.status).not_to eq("terminated")
      expect(adapter).not_to have_received(:terminate_instance)

      # 2. The audit trail the REST twin produces for the same operation.
      deferred = Ai::DeferredOperation.find_by(
        account_id: account.id, action_category: "system.task.terminate"
      )
      expect(deferred).to be_present,
                          "no DeferredOperation was parked: #{response.inspect}"
      expect(deferred.executor_class).to eq("System::Executors::TerminateInstance")
      expect(deferred.approval_request).to be_present

      # 3. Only then, the response shape.
      expect(response[:success]).to be(true)
      expect(response[:data][:pending]).to be(true)
      expect(response[:data][:deferred_operation_id]).to eq(deferred.id)
      expect(response[:data][:approval_request_id]).to eq(deferred.approval_request.id)
    end

    # "The arm parks" and "the parked operation still performs the work" are
    # two different claims, and only the second says the verb still functions.
    # Nothing is stubbed between the deferred operation and the executor, so a
    # params-key mismatch surfaces here rather than as a well-formed-looking
    # pending response.
    it "really terminates when the parked operation is approved" do
      response = terminate!
      deferred = Ai::DeferredOperation.find(response[:data][:deferred_operation_id])

      deferred.execute_now!

      expect(adapter).to have_received(:terminate_instance)
      expect(instance.reload.status).to eq("terminated")
    end
  end

  describe "the auto_approve tier" do
    before do
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
    end

    # On :proceed the EXECUTOR is the actor (Ai::AutonomyGate calls
    # execute_now! itself). The response shape is deliberately unchanged from
    # the pre-gate arm: gating this action cost it nothing but the policy check.
    it "terminates inline and reports it exactly as the ungated arm did" do
      response = terminate!

      expect(instance.reload.status).to eq("terminated")
      expect(adapter).to have_received(:terminate_instance)

      expect(response[:success]).to be(true)
      expect(response[:data][:terminated]).to be(true)
      expect(response[:data][:instance]).to be_present
    end
  end

  describe "the executor is the pre-gate call, not the REST task lane" do
    # REGRESSION GUARD. The obvious executor here was
    # System::Executors::ExecuteTask (what the REST twin uses), and it is
    # WRONG: its System::Task lane reaches the instance through
    # InstanceControlService, which includes no
    # System::Autonomy::SelfManagementFence and never calls
    # #finalize_termination! — so approving a terminate would have skipped
    # INV-1, the SDWAN peer detach, the deploy-key revocation and the meter
    # event. Pinning the actual call keeps a future "just reuse ExecuteTask"
    # simplification from silently dropping four controls.
    before do
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
      allow(::System::ProvisioningService).to receive(:terminate_instance)
        .and_return(::System::Runtime::Result.ok)
    end

    # THE control the executor choice exists to preserve. ExecuteTask's lane
    # (InstanceControlService) includes no SelfManagementFence at all, so under
    # that executor an approved terminate of this deployment's OWN hosting node
    # would proceed — the self-detach class
    # System::Compliance::RcpInvariantScanner asserts is "blocked at the
    # actuator". Tripping the fence for real is the only way to show the fix
    # kept it.
    it "still refuses INV-1 self-management, and terminates nothing" do
      ::SiteSetting.set(
        ::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY,
        instance.node_id
      )
      # Unstubbed here: the fence must refuse BEFORE the provider is reached.
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_call_original

      response = terminate!

      expect(instance.reload.status).not_to eq("terminated")
      expect(adapter).not_to have_received(:terminate_instance)
      expect(response[:success]).to be(false)
      expect(response[:error]).to match(/self-management|INV-1/)
    end

    it "routes the termination through ProvisioningService" do
      terminate!

      expect(::System::ProvisioningService).to have_received(:terminate_instance)
        .with(instance: instance)
      expect(::System::Task.where(account_id: account.id, command: "terminate")).to be_empty
    end
  end

  describe "authorization is not lost to the gate" do
    let(:user) { create(:user, account: account, permissions: []) }

    # A gated action never reaches #call, where this tool's per-action
    # permission check lives. Without BaseTool#authorization_error the gate
    # would have ESCALATED privilege: an unauthorized caller could park (and
    # have approved) a termination it was never allowed to request.
    it "refuses an unauthorized caller and parks nothing" do
      response = terminate!

      expect(response[:success]).to be(false)
      expect(response[:error]).to include("permission denied")
      expect(Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      expect(instance.reload.status).not_to eq("terminated")
    end
  end

  describe "the inner-action key cannot route around the gate" do
    # SystemFleetTool overrides #effective_action_name to WIDEN to a composer's
    # destroy-shaped inner op, which is correct for the deny overlay and wrong
    # for a registry lookup. Keying the governance registry off that method
    # would let a caller set a destructive INNER key alongside
    # `action: system_terminate_instance`: the lookup would resolve to the
    # inner name ("drain_instance" is in DESTRUCTIVE_TOOL_PATTERNS), match no
    # declaration, and fall through to #call — which dispatches on
    # params[:action]. #routed_action_name exists for exactly this.
    it "still gates when a destructive inner-action key is also supplied" do
      response = tool.execute(params: {
        action: "system_terminate_instance",
        instance_id: instance.id,
        op: "drain_instance"
      })

      # `pending` is the assertion that discriminates. The two below it are
      # redundant guards here — with the registry keyed off the widened name
      # the call would fall through to #call and hit the gate_routed_only
      # tripwire, which also terminates nothing — so they are stated as
      # corroboration, not as the oracle.
      expect(response[:data]).to include(pending: true)
      expect(instance.reload.status).not_to eq("terminated")
      expect(adapter).not_to have_received(:terminate_instance)
    end
  end

  describe "a cross-account target parks nothing" do
    let(:other_instance) { create(:system_node_instance, :running, account: create(:account)) }

    # Resolution happens in the gate context, BEFORE the operation is created —
    # otherwise an approval card would name another tenant's instance. It comes
    # back as the error ENVELOPE the pre-gate arm produced (SystemFleetTool#call
    # rescued RecordNotFound), not as an escaping exception: a gated action
    # returns before #call and so no longer benefits from that rescue, which is
    # why BaseTool#run_through_autonomy_gate carries its own.
    it "returns an error envelope without creating a deferred operation" do
      response = tool.execute(params: { action: "system_terminate_instance",
                                        instance_id: other_instance.id })

      expect(response[:success]).to be(false)
      expect(Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      expect(other_instance.reload.status).not_to eq("terminated")
    end
  end
end
