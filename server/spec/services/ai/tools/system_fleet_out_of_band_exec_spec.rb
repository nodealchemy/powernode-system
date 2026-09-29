# frozen_string_literal: true

require "rails_helper"

# IMP-9ce0ed39c557 — system_out_of_band_exec's MCP gating, mirroring
# system_fleet_terminate_gating_spec.rb's shape: THE ORACLE ASSERTS THE ROW
# (a DeferredOperation and, on approval, SshExecutionService actually being
# called), not merely the response shape.
RSpec.describe "SystemFleetTool out-of-band exec gating (IMP-9ce0ed39c557)" do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account, permissions: %w[system.instances.control]) }
  let(:tool)     { Ai::Tools::SystemFleetTool.new(account: account, user: user) }
  let(:node)     { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, :running, :with_ssh_host_key, node: node, account: account) }

  let(:ssh_result) do
    ::System::Runtime::Result.ok(data: { stdout: "ok", stderr: "", exit_code: 0, timed_out: false, truncated: false })
  end

  # Security review finding S2 — self_hosting_node_id must be CONFIGURED for
  # out-of-band-exec to run at all (fail-closed when unset). A decoy,
  # unrelated to `node`/`instance` and with no instances of its own, so
  # ordinary tests are unaffected; the INV-1 test below overrides it to
  # `node.id` explicitly.
  let(:self_hosting_node) { create(:system_node, account: create(:account)) }

  before do
    allow(::System::SshExecutionService).to receive(:execute_bounded).and_return(ssh_result)
    ::SiteSetting.set(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY,
                       self_hosting_node.id, setting_type: "string")
  end

  def run_exec!(**extra)
    tool.execute(params: { action: "system_out_of_band_exec", instance_id: instance.id, command: "uptime" }.merge(extra))
  end

  describe "the declaration" do
    let(:declaration) { Ai::Tools::SystemFleetTool.declared_action("system_out_of_band_exec") }

    it "is destructive, gated under system.instance.out_of_band_exec, and actuated by the shared executor" do
      expect(declaration[:destructive]).to be true
      expect(declaration[:action_category]).to eq(::System::OutOfBandExecService::ACTION_CATEGORY)
      expect(declaration[:action_category]).to eq("system.instance.out_of_band_exec")
      expect(declaration[:executor_class]).to eq("System::Executors::OutOfBandExec")
    end

    it "is human_only (security review finding S1) — no policy row or tool door may approve it" do
      expect(declaration[:human_only]).to be true
    end

    it "is NOT a reuse of system.task.ssh_command" do
      expect(declaration[:action_category]).not_to eq("system.task.ssh_command")
    end

    it "is registered in the tool catalog" do
      expect(::Ai::Tools::PlatformApiToolRegistry.all_tools["system_out_of_band_exec"])
        .to eq("Ai::Tools::SystemFleetTool")
    end

    it "is a category the platform actually declares, at require_approval, with no owning agent" do
      expect(::System::Governance::PolicyDeclarations::OUT_OF_BAND_EXEC_POLICIES)
        .to include(declaration[:action_category] => "require_approval")
      expect(::System::Governance::PolicyDeclarations.owner_of(declaration[:action_category])).to be_nil
    end
  end

  describe "the seeded require_approval tier (default resolution)" do
    it "parks an approval and never calls SshExecutionService" do
      response = run_exec!

      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)

      deferred = ::Ai::DeferredOperation.find_by(
        account_id: account.id, action_category: ::System::OutOfBandExecService::ACTION_CATEGORY
      )
      expect(deferred).to be_present, "no DeferredOperation was parked: #{response.inspect}"
      expect(deferred.executor_class).to eq("System::Executors::OutOfBandExec")
      expect(deferred.approval_request).to be_present
      expect(deferred.params["command"]).to eq("uptime")
      expect(deferred.params["pinned_ip"]).to eq(instance.ssh_ip_address)
      # Review finding R2-1 — the approver must see WHERE this will run, not
      # just the instance's name.
      expect(deferred.description).to include(instance.ssh_ip_address)

      expect(response[:success]).to be(true)
      expect(response[:data][:pending]).to be(true)
      expect(response[:data][:deferred_operation_id]).to eq(deferred.id)
    end

    # Security review finding S1 — human_only marks the opened request.
    it "marks the opened approval request requires_human_session" do
      response = run_exec!

      deferred = ::Ai::DeferredOperation.find(response[:data][:deferred_operation_id])
      expect(deferred.approval_request.requires_human_session?).to be true
      expect(response[:data][:requires_human_session]).to be true
    end

    it "really runs the bounded SSH call once the parked operation is approved" do
      response = run_exec!
      deferred = ::Ai::DeferredOperation.find(response[:data][:deferred_operation_id])

      # A real decision, not just execute_now! (security review finding S4 —
      # OutOfBandExecService now asserts the backing Ai::ApprovalRequest is
      # itself APPROVED, so a request left `pending` refuses at execution
      # time even though the DeferredOperation's own AASM state moves to
      # "executing"). update_columns rather than the full
      # ApprovalWorkflowService/chain-approver dance: this test's oracle is
      # OutOfBandExecService actually being reached, not who may decide a
      # chain step, which is covered elsewhere.
      deferred.approval_request.update_columns(status: "approved", completed_at: Time.current)

      deferred.execute_now!

      expect(::System::SshExecutionService).to have_received(:execute_bounded).with(
        hash_including(instance: instance, command: "uptime", sudo: true)
      )
    end
  end

  # Security review finding S1 — no policy row can let this run with no
  # person confirming it. auto_approve/notify_and_proceed both get forced to
  # require_approval by Ai::AutonomyGate#evaluate whenever
  # requires_human_session is set, independent of what the resolved policy
  # says.
  describe "the auto_approve tier is overridden by human_only (security review finding S1)" do
    before do
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
    end

    it "still parks for a human decision rather than running inline" do
      response = run_exec!

      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
      expect(response[:success]).to be(true)
      expect(response[:data][:pending]).to be(true)
      expect(response[:data][:requires_human_session]).to be(true)

      deferred = ::Ai::DeferredOperation.find(response[:data][:deferred_operation_id])
      expect(deferred.approval_request.requires_human_session?).to be true
    end
  end

  describe "approving through an MCP tool door is refused (security review finding S1)" do
    # A DIFFERENT user, holding the permission approve_deferred_operation
    # itself requires (ai.autonomy.approve) — so the refusal under test is
    # requires_human_session?, not a permission check ahead of it.
    let(:approver) { create(:user, account: account, permissions: %w[ai.autonomy.approve]) }

    it "approve_deferred_operation refuses an out-of-band-exec request, pointing at the Autonomy dashboard" do
      response = run_exec!
      deferred = ::Ai::DeferredOperation.find(response[:data][:deferred_operation_id])
      expect(deferred.approval_request.requires_human_session?).to be true

      approver_tool = ::Ai::Tools::AgentAutonomyTool.new(account: account, user: approver)
      decision = approver_tool.execute(
        params: { action: "approve_deferred_operation", deferred_operation_id: deferred.id }
      )

      expect(decision[:success]).to be(false)
      expect(decision[:requires_human_session]).to be(true)
      expect(deferred.approval_request.reload.status).to eq("pending")
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end
  end

  describe "pre-park refusals — never create a DeferredOperation" do
    it "refuses a blank command" do
      response = tool.execute(params: { action: "system_out_of_band_exec", instance_id: instance.id, command: "" })

      expect(response[:success]).to be(false)
      expect(::Ai::DeferredOperation.where(account: account)).to be_empty
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end

    # Review finding #5: parking with a blank ssh_ip_address would store a
    # nil pinned_ip, which OutOfBandExecService's own pin-match refusal can
    # never meaningfully fire against later.
    it "refuses to park when the instance has no SSH IP address to pin" do
      # ssh_ip_address is derived (vpn > private > public IP), never its own
      # column — clear all three real columns on the persisted row so the
      # TOOL's own fresh #find sees the same blank state, not just this
      # in-memory `instance` object.
      instance.update_columns(vpn_ip_address: nil, private_ip_address: nil, public_ip_address: nil)

      response = run_exec!

      expect(response[:success]).to be(false)
      expect(response[:error]).to match(/no SSH IP/i)
      expect(::Ai::DeferredOperation.where(account: account)).to be_empty
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end

    it "refuses an unknown instance id" do
      response = tool.execute(params: { action: "system_out_of_band_exec", instance_id: SecureRandom.uuid, command: "uptime" })

      expect(response[:success]).to be(false)
      expect(::Ai::DeferredOperation.where(account: account)).to be_empty
    end

    it "refuses a foreign account's instance id" do
      foreign = create(:system_node_instance, :running,
                       node: create(:system_node, account: create(:account)))
      response = tool.execute(params: { action: "system_out_of_band_exec", instance_id: foreign.id, command: "uptime" })

      expect(response[:success]).to be(false)
      expect(::Ai::DeferredOperation.where(account: account)).to be_empty
    end

    it "refuses this control plane's own self-hosting node before parking (INV-1)" do
      ::SiteSetting.set(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY, node.id, setting_type: "string")

      response = run_exec!

      expect(response[:success]).to be(false)
      expect(response[:error]).to match(/INV-1|self-management/i)
      expect(::Ai::DeferredOperation.where(account: account)).to be_empty
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end

    # Security review finding S2 — fails closed, unlike SelfManagementFence's
    # own inert-by-default for every other consumer.
    it "refuses before parking when self_hosting_node_id has never been configured" do
      ::SiteSetting.where(key: ::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY).delete_all

      response = run_exec!

      expect(response[:success]).to be(false)
      expect(response[:error]).to match(/self_hosting_node_id/i)
      expect(::Ai::DeferredOperation.where(account: account)).to be_empty
    end

    it "refuses before parking a loopback SSH address" do
      instance.update_columns(private_ip_address: "127.0.0.1", vpn_ip_address: nil, public_ip_address: nil)

      response = run_exec!

      expect(response[:success]).to be(false)
      expect(response[:error]).to match(/loopback/i)
      expect(::Ai::DeferredOperation.where(account: account)).to be_empty
    end

    # Security review, command-text decision — refused before parking, and
    # never echoed in the error.
    it "refuses a secret-shaped command before parking, without echoing it" do
      response = tool.execute(params: { action: "system_out_of_band_exec", instance_id: instance.id,
                                        command: "export PASSWORD=hunter2-secret-pw" })

      expect(response[:success]).to be(false)
      expect(response[:error]).to match(/secret-shaped/i)
      expect(response[:error]).not_to include("hunter2-secret-pw")
      expect(::Ai::DeferredOperation.where(account: account)).to be_empty
    end
  end

  # Review finding C2-4-round-3 — a no-op today (every real MCP session
  # carries a user; see the gate_context comment), but a future in-process
  # caller building this tool with an agent and NO user (an autonomous
  # request acting for no one) must be refused BEFORE parking, not only at
  # execution time (System::OutOfBandExecService#execute!'s own C2-4
  # re-check already fails closed there, on the SAME "cannot resolve a
  # requester" reasoning — this test pins the pre-park half).
  describe "an autonomous caller with no user is refused before parking (review finding C2-4-round-3)" do
    it "refuses a call carrying an agent but no user" do
      agent = create(:ai_agent, account: account)
      agentless_tool = ::Ai::Tools::SystemFleetTool.new(account: account, user: nil, agent: agent, internal: true)

      response = agentless_tool.execute(
        params: { action: "system_out_of_band_exec", instance_id: instance.id, command: "uptime" }
      )

      expect(response[:success]).to be(false)
      expect(response[:error]).to match(/requesting user/i)
      expect(::Ai::DeferredOperation.where(account: account)).to be_empty
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end
  end

  describe "instance principal — refused at TWO independent layers" do
    let(:node_instance_principal) { instance }

    def run_as_instance!
      instance_tool = ::Ai::Tools::SystemFleetTool.new(account: account, user: nil)
      instance_tool.instance_authorized = true
      instance_tool.node_instance = node_instance_principal
      instance_tool.execute(params: { action: "system_out_of_band_exec", instance_id: instance.id,
                                      command: "uptime" }.with_indifferent_access)
    end

    it "layer 1 — Mcp::Principal::DESTRUCTIVE_TOOL_PATTERNS denies the tool name outright" do
      expect(::Mcp::Principal.destructive_tool?("system_out_of_band_exec")).to be true
    end

    # Direct, mirroring #dr_lane_reap_by_instance_principal!'s own spec idiom:
    # this layer must hold on its own, independent of the overlay pattern
    # list above ever changing.
    it "layer 2 — out_of_band_exec_gate_context refuses instance_authorized? directly" do
      instance_tool = ::Ai::Tools::SystemFleetTool.new(account: account, user: nil)
      instance_tool.instance_authorized = true
      instance_tool.node_instance = instance

      expect {
        instance_tool.send(:out_of_band_exec_gate_context, { instance_id: instance.id, command: "uptime" })
      }.to raise_error(a_kind_of(StandardError), /instance principal/i)
    end

    # Review finding #9: asserting only `be_a(StandardError)` cannot fail —
    # StandardError is the ancestor of nearly every exception Ruby raises, so
    # an unrelated bug elsewhere in the call path (a typo'd method, a nil
    # dereference) would satisfy this just as well as the real refusal would.
    # This end-to-end call is actually refused at LAYER 1
    # (BaseTool#enforce_instance_deny_overlay!, ahead of #call and therefore
    # ahead of #out_of_band_exec_gate_context ever running) — assert that
    # SPECIFIC class and message, not merely "some exception happened".
    it "an instance principal is refused end-to-end even if it has self-granted the exact tool name" do
      expect { run_as_instance! }.to raise_error(
        ::Mcp::ProtocolService::PermissionDeniedError, /destroy-shaped/i
      )
      expect(::Ai::DeferredOperation.where(account: account)).to be_empty
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end
  end
end
