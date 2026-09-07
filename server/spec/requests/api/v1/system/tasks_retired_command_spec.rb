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
