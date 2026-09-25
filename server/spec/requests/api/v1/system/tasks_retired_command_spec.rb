# frozen_string_literal: true

require "rails_helper"

# Campaign 01a0790b increment 2 removed `terminate` from System::Task::COMMANDS
# — the agent answers a terminate Task with `systemctl reboot`, so the row was
# advertising a destroy that brought the VM back instead.
#
# WHY A CONTROLLER GUARD AND NOT JUST THE MODEL VALIDATION. The category
# OUTLIVES the command on purpose: System::Governance::PolicyDeclarations::
# GATED_NON_COMMAND_OPERATIONS keeps `system.task.terminate` declared, because
# both lifecycle surfaces still gate the real destroy there. So the request
# still RESOLVES a policy, and that policy is require_approval. Without a
# pre-gate refusal the sequence is:
#
#   POST {"command":"terminate"} → gate → :pending → an approval request parks
#   → an operator approves it → ExecuteTask#perform → save! → RecordInvalid
#
# i.e. an approval an operator can grant that the platform can never honour.
# The 422 has to land BEFORE Ai::AutonomyGate.evaluate, which is what the
# gate-not-called expectation below actually pins — a 422 on its own proves
# nothing here, since a :blocked gate decision renders the same status.
RSpec.describe "POST /api/v1/system/tasks retired command", type: :request do
  let(:user)      { user_with_permissions("system.infra_tasks.create", "system.instances.read") }
  let(:account)   { user.account }
  let(:node)      { create(:system_node, account: account) }
  let!(:instance) { create(:system_node_instance, node: node, name: "web-1") }

  def create_task(command, options = nil)
    body = { command: command, operable_type: "System::NodeInstance", operable_id: instance.id }
    body[:options] = options unless options.nil?
    post "/api/v1/system/tasks",
         params: { task: body }.to_json,
         headers: auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  context "with a command the platform no longer executes" do
    it "refuses without creating a task" do
      expect { create_task("terminate") }.not_to change { account.system_tasks.count }

      expect(response).to have_http_status(:unprocessable_content)
    end

    # The failure this guard exists to prevent. Ai::AutonomyGate.evaluate
    # creates the Ai::DeferredOperation UNCONDITIONALLY, before it switches on
    # the resolved policy (ai/autonomy_gate.rb #evaluate → #create_deferred_
    # operation!), so "count unchanged" means the gate was never entered — for
    # every policy, in both core and business mode.
    #
    # Ai::ApprovalRequest is the row an operator actually grants, and counting
    # THAT would pass vacuously in a public clone: with no Ai::ApprovalChain
    # loaded, require_approval auto-proceeds and parks no request at all
    # (#require_approval_or_proceed). The deferred operation is the row that
    # exists on every path.
    it "creates no deferred operation for an operator to be offered" do
      expect { create_task("terminate") }.not_to change { ::Ai::DeferredOperation.count }

      expect(response).to have_http_status(:unprocessable_content)
    end

    # THE DISCRIMINATOR. :blocked also renders 422, so reaching the gate at all
    # would satisfy every assertion above while leaving the parked-approval
    # hazard intact for any policy that resolves to require_approval.
    it "never reaches the autonomy gate" do
      expect(::Ai::AutonomyGate).not_to receive(:evaluate)

      create_task("terminate")

      # Anchored: without this, the example is also satisfied by a 403 from
      # require_permission or a 400 from param parsing — neither of which is
      # the refusal under test.
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "names the route that does destroy an instance" do
      create_task("terminate")

      expect(response.body).to include("system_terminate_instance")
      expect(response.body).to include("System::Executors::TerminateInstance")
    end
  end

  # `start` and `stop` join `terminate` as commands whose CATEGORY outlives the
  # command (IMP-01a079f5-2322 follow-on). The reasoning is identical and the
  # evidence is stronger:
  #
  #   * the agent — the sole actuator of a System::Task since increment 3 —
  #     binds both to LifecycleHandler behind validateUnit
  #     (runtime/tasks/handlers/lifecycle.go:75,117-118), so a row without
  #     options["unit"] is ALWAYS refused on the node. Unlike `restart`, the
  #     model required no scope declaration, so the platform minted rows the
  #     agent could never run.
  #   * a full census of the control plane — all 923 System::Task rows that
  #     exist, walked to has_more:false — carries ZERO `start` and ZERO `stop`.
  #     Nothing is being taken from a working path.
  #   * the real capability is the PROVIDER plane:
  #     Api::V1::System::NodeInstanceGating::LIFECYCLE_EXECUTORS routes both to
  #     System::Executors::ControlInstance, and the MCP verbs
  #     system_start_instance / system_stop_instance route to the same executor.
  #     Both gate on system.task.start / system.task.stop, which is why those
  #     categories stay declared in GATED_NON_COMMAND_OPERATIONS.
  context "with a command that is gated here but actuated on the provider plane" do
    %w[start stop].each do |command|
      it "refuses #{command} without creating a task" do
        expect { create_task(command) }.not_to change { account.system_tasks.count }

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "creates no deferred operation for #{command}" do
        expect { create_task(command) }.not_to change { ::Ai::DeferredOperation.count }
      end

      # Same discriminator as terminate above: :blocked renders 422 too, so
      # only "the gate was never entered" distinguishes a pre-gate refusal from
      # a policy decision.
      it "never reaches the autonomy gate for #{command}" do
        expect(::Ai::AutonomyGate).not_to receive(:evaluate)

        create_task(command)

        expect(response).to have_http_status(:unprocessable_content)
      end

      # A refusal that does not say where the capability went is a capability
      # an operator concludes was removed.
      it "names the route that does #{command} an instance" do
        create_task(command)

        expect(response.body).to include("system_#{command}_instance")
        expect(response.body).to include("System::Executors::ControlInstance")
      end
    end

    # THE HALF THAT MUST NOT CHANGE. Removing the command must not remove the
    # operator's control over the operation: both categories stay registered
    # (PATCH /api/v1/ai/intervention_policies/bulk refuses to save a row for an unregistered
    # name) and stay declared with their existing auto_approve verb, so no
    # install silently tightens or loosens.
    it "keeps both categories registered and tunable" do
      %w[system.task.start system.task.stop].each do |category|
        expect(::Ai::InterventionPolicy.category_registered?(category)).to be(true),
               "#{category} lost its registration; the provider-plane gate composes it"
        expect(::System::Governance::PolicyDeclarations::MANUAL_OPERATION_POLICIES[category])
          .to eq("auto_approve")
      end
    end
  end

  # VACUITY GUARD. Every example above passes if the controller refuses
  # EVERYTHING, so one listed command must still get through to the gate.
  context "with a listed command" do
    before do
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
    end

    it "reaches the gate and creates the task" do
      expect { create_task("reboot") }.to change { account.system_tasks.count }.by(1)

      expect(response).to have_http_status(:created)
    end
  end
end
