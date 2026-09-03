# frozen_string_literal: true

require "rails_helper"

# `restart` is the one System::Task command whose NAME does not say what it
# does. Until the scope became a DECLARATION, the choice between its two
# actuators was inferred downstream from whether options["unit"] happened to be
# set — which made the destructive reading the DEFAULT:
#
#   POST /api/v1/system/tasks {"command": "restart"}
#
# is the obvious way for an operator to ask for a service bounce, and it
# rebooted the entire VM through the provider adapter. On a self-hosted control
# plane that is the machine serving the request.
#
# This is the operator-facing surface of that hazard. The model validation is
# the chokepoint (spec/models/system/task_spec.rb); this asserts an operator
# actually gets a refusal they can act on rather than a reboot.
RSpec.describe "POST /api/v1/system/tasks restart scope", type: :request do
  let(:user)      { user_with_permissions("system.infra_tasks.create", "system.instances.read") }
  let(:account)   { user.account }
  let(:node)      { create(:system_node, account: account) }
  let!(:instance) { create(:system_node_instance, node: node, name: "web-1") }

  # Forces the gate's :proceed branch, where ExecuteTask runs inline. No
  # InterventionPolicy rows exist in a spec account, so the service otherwise
  # falls through to its require_approval default and the task is only built at
  # approval time. Production DECLARES `system.task.restart` as require_approval
  # (IMP-0c1a7dca5781) — an install seeded before that change may still hold the
  # older auto_approve row — so the stub, not the seed, is what puts this spec on
  # the :proceed branch.
  before do
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
    # The after_commit pushes straight to Redis; nothing here is testing that.
    allow(::System::WorkerDispatch).to receive(:enqueue_operation_execution)
  end

  def create_task(options)
    body = { command: "restart", operable_type: "System::NodeInstance", operable_id: instance.id }
    body[:options] = options unless options.nil?
    post "/api/v1/system/tasks",
         params: { task: body }.to_json,
         headers: auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  def created_task
    account.system_tasks.where(command: "restart").order(created_at: :desc).first
  end

  context "when the request declares no scope" do
    it "is refused instead of rebooting the VM" do
      expect { create_task(nil) }.not_to change { account.system_tasks.count }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "tells the operator what to declare" do
      create_task({})

      message = response.parsed_body.to_json
      expect(message).to include("scope")
      expect(message).to include("unit")
      expect(message).to include("instance")
    end
  end

  context "when the request declares scope unit" do
    let(:unit) { "powernode-019f7cb5-3858-7caa-aa9f-51629dc8e573-rails.service" }

    it "creates a task the AGENT will execute, not the provider" do
      expect { create_task({ "scope" => "unit", "unit" => unit }) }
        .to change { account.system_tasks.count }.by(1)

      expect(response).to have_http_status(:created)
      task = created_task
      expect(task.options["unit"]).to eq(unit)
      expect(::System::ExecutionDispatcher.agent_delegated?(task.command, task.options)).to be true
    end

    it "refuses a unit scope that names no unit" do
      expect { create_task({ "scope" => "unit" }) }.not_to change { account.system_tasks.count }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  context "when the request declares scope instance" do
    it "creates the whole-VM reboot the operator explicitly asked for" do
      expect { create_task({ "scope" => "instance" }) }
        .to change { account.system_tasks.count }.by(1)

      expect(response).to have_http_status(:created)
      task = created_task
      expect(::System::ExecutionDispatcher.agent_delegated?(task.command, task.options)).to be false
      expect(::System::ExecutionDispatcher::COMMAND_REGISTRY[task.command])
        .to eq(::System::Runtime::ControlInstance)
    end

    # A declared VM reboot that also names a unit is a contradiction, not a
    # harmless extra key: the VM reboots and the named unit is never restarted,
    # so what runs is not what the caller said.
    it "refuses an instance scope that also names a unit" do
      expect { create_task({ "scope" => "instance", "unit" => "x.service" }) }
        .not_to change { account.system_tasks.count }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
