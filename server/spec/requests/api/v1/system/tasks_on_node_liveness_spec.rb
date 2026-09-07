# frozen_string_literal: true

require "rails_helper"

# IMP-93d9f4a31627 — the SIXTH on-node task producer, and the last ungated one
# the liveness census found.
#
#   POST /api/v1/system/tasks
#     -> Api::V1::System::TasksController#create
#     -> Ai::AutonomyGate
#     -> System::Executors::ExecuteTask#perform
#     -> ::System::Task.new(attrs) ... task.save!
#
# `task_params` permits :command freely and System::Task::COMMANDS contains
# both sync_modules and apply_config, so an authenticated operator could mint
# exactly the row the liveness work exists to prevent — an on-node reconcile
# task aimed at an instance whose agent is gone, which then sits pending until
# the worker janitor cancels it, with nothing in the event stream saying why.
#
# It stayed invisible to five prior enumerations for three reasons at once: the
# construction is `Task.new` + `save!` rather than `create!`; the command
# arrives in a params hash rather than as a literal or a named variable; and
# the site is in a service reached through a gate, not in the fleet or MCP code
# anyone was auditing.
#
# SEVERITY, which the offer left open: it is NOT approval-gated.
# PolicyDeclarations::MANUAL_OPERATION_DEFAULT_VERBS declares sync_modules
# auto_approve and apply_config notify_and_proceed, so no operator is asked
# about either — the row is minted inline on the request.
RSpec.describe "POST /api/v1/system/tasks on-node liveness", type: :request do
  let(:user)    { user_with_permissions("system.infra_tasks.create", "system.instances.read") }
  let(:account) { user.account }
  let(:node)    { create(:system_node, account: account) }

  # Forces the gate's :proceed branch, where ExecuteTask runs inline — the same
  # stub tasks_restart_scope_spec.rb uses and for the same reason (a spec
  # account holds no InterventionPolicy rows, so the service would otherwise
  # fall through to its require_approval default and build nothing).
  before do
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  # The `allow(::System::WorkerDispatch).to receive(:enqueue_operation_execution)`
  # stub that used to sit in the before block above is gone with the class.
  # VERIFIED, not assumed: System::WorkerDispatch had exactly one caller in the
  # tree — System::Task#enqueue_execution — and campaign 01a0790b increment 3
  # deleted both, along with the after_commit that reached it. This spec's
  # sibling stubs elsewhere were removed by that increment with the same note;
  # this one survived only because it arrived on dev-loop/dev-improve and the
  # two branches met at the merge.

  def create_task(command:, instance:)
    post "/api/v1/system/tasks",
         params: {
           task: {
             command: command,
             operable_type: "System::NodeInstance",
             operable_id: instance.id
           }
         }.to_json,
         headers: auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  # `running` with no heartbeat is #silence_verdict's :never_reported — the
  # control plane marked it running from provider state alone.
  let(:never_reported) do
    create(:system_node_instance, node: node, name: "never-reported",
                                  status: "running", last_heartbeat_at: nil)
  end

  let(:went_silent) do
    create(:system_node_instance, node: node, name: "went-silent",
                                  status: "running", last_heartbeat_at: 30.minutes.ago)
  end

  # Outside LIVE_REPLICA_STATUSES — #offline_dispatch_refusal's arm.
  let(:errored) do
    create(:system_node_instance, node: node, name: "errored",
                                  status: "error", last_heartbeat_at: 10.seconds.ago)
  end

  let(:live) do
    create(:system_node_instance, node: node, name: "live",
                                  status: "running", last_heartbeat_at: 10.seconds.ago)
  end

  # Inside LIVE_REPLICA_STATUSES, outside HEARTBEAT_EXPECTED_STATUSES —
  # #dormant_agent_reason's arm.
  let(:dormant) do
    create(:system_node_instance, node: node, name: "dormant",
                                  status: "stopped", last_heartbeat_at: 10.seconds.ago)
  end

  %w[sync_modules apply_config].each do |command|
    describe "#{command} for an instance whose agent will never pull it" do
      it "refuses a running instance that has never reported" do
        expect { create_task(command: command, instance: never_reported) }
          .not_to change { account.system_tasks.count }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]).to match(/never reported/)
        # DISCRIMINATES the controller arm from the executor arm. Delete the
        # controller pre-check and the executor's raise still produces a 422
        # carrying this same text — Ai::AutonomyGate rescues it into
        # `:blocked` with "Gate evaluation failed: ..." — so without this the
        # example would pass with either arm alone.
        expect(response.parsed_body["error"]).not_to match(/Gate evaluation failed/)
      end

      it "refuses a running instance whose agent went silent" do
        expect { create_task(command: command, instance: went_silent) }
          .not_to change { account.system_tasks.count }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]).to match(/went silent/)
        expect(response.parsed_body["error"]).not_to match(/Gate evaluation failed/)
      end

      it "refuses an instance whose status left LIVE_REPLICA_STATUSES" do
        expect { create_task(command: command, instance: errored) }
          .not_to change { account.system_tasks.count }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]).to match(/no agent will pull/)
        expect(response.parsed_body["error"]).not_to match(/Gate evaluation failed/)
      end

      it "parks no approval and creates no deferred operation for a refused request" do
        expect { create_task(command: command, instance: went_silent) }
          .not_to change { ::Ai::DeferredOperation.count }
        expect { create_task(command: command, instance: went_silent) }
          .not_to change { ::Ai::ApprovalRequest.count }
      end

      it "never reaches the autonomy gate" do
        expect(::Ai::AutonomyGate).not_to receive(:evaluate)
        create_task(command: command, instance: went_silent)
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    describe "#{command} for an instance an agent can be expected to pull it" do
      it "creates the task" do
        expect { create_task(command: command, instance: live) }
          .to change { account.system_tasks.count }.by(1)

        expect(response).to have_http_status(:created)
      end
    end

    describe "#{command} for a dormant instance" do
      # NOT a refusal, deliberately, and the distinction is the one
      # NodeInstance#dormant_agent_reason draws: a stopped box is not evidence
      # of a dead agent, the task IS pulled when one starts, and refusing an
      # operator's explicit request here would trade a visible pending task for
      # a refused repair. What must not happen is a BARE success — the same
      # defect IMP-cdf18862a7c1's review caught on system_refresh_instance_modules,
      # where an operator resyncing a box powered down last week got no warning.
      it "creates the task" do
        expect { create_task(command: command, instance: dormant) }
          .to change { account.system_tasks.count }.by(1)

        expect(response).to have_http_status(:created)
      end

      it "discloses that nothing is running to pull it yet" do
        create_task(command: command, instance: dormant)

        expect(response.parsed_body.dig("data", "dormant_agent_warning"))
          .to match(/no agent is running/)
      end

      it "says nothing of the kind for a live instance" do
        create_task(command: command, instance: live)

        # KEY ABSENCE, not a nil value: `dig` answers nil for both, so asserting
        # the value would still pass with the key removed from the response
        # entirely — the example would then be pinning nothing.
        expect(response.parsed_body.fetch("data")).not_to have_key("dormant_agent_warning")
      end
    end
  end

  # THE SHAPE THE FIRST DRAFT OF THIS GATE FELL OPEN ON, and the one the
  # executor's own spec drives for nearly every happy path:
  # System::Runtime::SyncModules accepts a Node operable and fans the sync out
  # across `node.node_instances`. An inline
  # `operable.respond_to?(:on_node_dispatch_refusal)` test answers false for a
  # Node and lets the row through — a respond_to? guard fails SILENTLY when the
  # receiver is the wrong type, so the census read :gated while the dominant
  # spelling was ungated.
  describe "a Node operable, which fans out across the node's instances" do
    def create_node_task(command:, node_record:)
      post "/api/v1/system/tasks",
           params: {
             task: {
               command: command,
               operable_type: "System::Node",
               operable_id: node_record.id
             }
           }.to_json,
           headers: auth_headers_for(user).merge("Content-Type" => "application/json")
    end

    let(:dead_node) { create(:system_node, account: account, name: "all-dead") }
    let(:mixed_node) { create(:system_node, account: account, name: "one-alive") }

    it "refuses when EVERY instance of the node is unreachable" do
      create(:system_node_instance, node: dead_node, name: "d1",
                                    status: "running", last_heartbeat_at: nil)
      create(:system_node_instance, node: dead_node, name: "d2",
                                    status: "running", last_heartbeat_at: 40.minutes.ago)

      expect { create_node_task(command: "sync_modules", node_record: dead_node) }
        .not_to change { account.system_tasks.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to match(/every instance of/)
      expect(response.parsed_body["error"]).to match(/d1/).and match(/d2/)
    end

    it "still queues when ONE instance is reachable — a partly-dead node has work to do" do
      create(:system_node_instance, node: mixed_node, name: "m-dead",
                                    status: "running", last_heartbeat_at: 40.minutes.ago)
      create(:system_node_instance, node: mixed_node, name: "m-live",
                                    status: "running", last_heartbeat_at: 5.seconds.ago)

      expect { create_node_task(command: "sync_modules", node_record: mixed_node) }
        .to change { account.system_tasks.count }.by(1)

      expect(response).to have_http_status(:created)
    end

    it "discloses rather than refuses when every instance is merely dormant" do
      create(:system_node_instance, node: mixed_node, name: "m-stopped",
                                    status: "stopped", last_heartbeat_at: 10.seconds.ago)

      expect { create_node_task(command: "sync_modules", node_record: mixed_node) }
        .to change { account.system_tasks.count }.by(1)

      expect(response).to have_http_status(:created)
      warning = response.parsed_body.dig("data", "dormant_agent_warning")
      expect(warning).to match(/no agent is running/)
      # The two arms mean OPPOSITE things and must not share a word: an earlier
      # draft built one message tail reading "is unreachable" for both, so a
      # 201 carried the refusal's vocabulary.
      expect(warning).not_to match(/unreachable/)
    end

    # System::ProviderRegion is an OPERABLE_TYPES member that ALSO declares
    # `has_many :node_instances`, so a duck-typed `respond_to?(:node_instances)`
    # fan-out fired for it — asking a liveness question no dispatcher acts on
    # (Runtime::SyncModules handles NodeInstance and Node and errors on the
    # rest) while loading every instance in the region on a request path. The
    # seam dispatches on class for this reason.
    it "does not fan out across an operable that merely happens to have instances" do
      # IN THIS ACCOUNT, deliberately: a factory region with no account is
      # refused by ExecuteTask#resolve_scoped as cross-account BEFORE the seam
      # runs, so the example would pass against the duck-typed version it
      # exists to reject — verified by mutation, which is how the first draft
      # of this example was caught.
      region = create(:system_provider_region, account: account)
      create(:system_node_instance, node: dead_node, name: "r1", provider_region: region,
                                    status: "running", last_heartbeat_at: nil)

      post "/api/v1/system/tasks",
           params: {
             task: {
               command: "sync_modules",
               operable_type: "System::ProviderRegion",
               operable_id: region.id
             }
           }.to_json,
           headers: auth_headers_for(user).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["error"].to_s).not_to match(/unreachable|never reported/)
    end

    it "does not refuse a node with no instances at all" do
      empty = create(:system_node, account: account, name: "empty")

      expect { create_node_task(command: "sync_modules", node_record: empty) }
        .to change { account.system_tasks.count }.by(1)

      expect(response).to have_http_status(:created)
    end
  end

  describe "an on-node command with no operable at all" do
    # System::Task's operable is `optional: true` and executors/execute_task
    # _spec pins that such a row is still created. There is no target to ask
    # about, so the seam's case/else answers nil — and that is deliberately NOT
    # a claim the row is deliverable. Delivery is per-instance, so an
    # operable-less row reaches no agent either; that is offer 01a079f5-2322's
    # question, not this gate's.
    #
    # HONEST ABOUT WHAT THIS PINS: nil falls to the case's else arm, which no
    # single deletion can turn into a refusal, so this example cannot red on a
    # mutation of the branch it documents. It guards the END-TO-END path — that
    # adding a gate to #create did not start refusing operable-less creates —
    # which is a regression the other examples would not catch.
    it "is still created" do
      post "/api/v1/system/tasks",
           params: { task: { command: "sync_modules" } }.to_json,
           headers: auth_headers_for(user).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:created)
    end
  end

  describe "commands that are not on-node reconciles" do
    # The gate is scoped to the two commands an AGENT must pull. A `stop`
    # against a silent instance is actuated by the platform through the
    # provider, so refusing it would break the one lane that still works when
    # an agent is gone.
    it "still accepts start for an instance whose agent went silent" do
      expect { create_task(command: "start", instance: went_silent) }
        .to change { account.system_tasks.count }.by(1)

      expect(response).to have_http_status(:created)
    end
  end

  describe "the executor refuses too, not only the controller" do
    # The controller check is the operator-facing refusal. The EXECUTOR check
    # is the load-bearing one: a deferred operation approved hours later
    # replays through ExecuteTask#perform with no controller in the path, and
    # NodeInstanceGating's gate_or_execute reaches the same executor by
    # another door. Fixing only the mint path and leaving the replay
    # grandfathered is a defect this loop has shipped once already, in a guard
    # whose create/update paths were repaired while its activate verb still
    # gated on a method that refused nothing.
    it "raises rather than minting the row when a parked operation replays" do
      params = {
        task_attributes: {
          command: "sync_modules",
          operable_type: "System::NodeInstance",
          operable_id: went_silent.id,
          initiated_by_id: user.id
        }
      }
      # A real DeferredOperation, because that is what a replay carries and it
      # is where the executor reads its account anchor from.
      operation = ::Ai::DeferredOperation.create!(
        account: account,
        action_category: "system.task.sync_modules",
        executor_class: "System::Executors::ExecuteTask",
        params: params,
        requested_by: user,
        status: "pending"
      )
      executor = ::System::Executors::ExecuteTask.new(params, deferred_operation: operation)

      expect { executor.call }
        .to raise_error(::System::Task::UndeliverableOnNodeTask, /went silent/)
      expect(account.system_tasks.where(command: "sync_modules")).to be_empty
    end
  end
end
