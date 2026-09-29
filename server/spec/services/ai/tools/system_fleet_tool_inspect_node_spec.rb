# frozen_string_literal: true

require "rails_helper"

# IMP-52762a704a3d — system_inspect_node, the routine READ-ONLY node inspection
# verb. It queues one probe.node_inspect task on an instance (fixed collectors,
# validated arguments; System::NodeInspection) and long-polls for the agent's
# result. It is the routine sibling of system_out_of_band_exec and shares
# nothing with it: no approval, no ssh.
#
# THE SELF-ONLY RULE is the security property and is keyed on the PRINCIPAL,
# not on the verb: an instance principal (instance_authorized, no user) may
# inspect ONLY the node identity it authenticated as, whatever instance_id it
# passes. User principals are account-scoped.
#
# ORACLE SHAPE: every refusal asserts NO TASK ROW was created, never just the
# response body (a guard that renders a refusal after the insert still inserts).
# Each refusal is paired with the permitted opposite so "refuse everything"
# cannot pass this file.
RSpec.describe Ai::Tools::SystemFleetTool, "system_inspect_node" do
  include ActiveSupport::Testing::TimeHelpers

  let(:account)  { create(:account) }
  # system.nodes.read is the tool floor Ai::Executors::DeferredToolCall re-asks
  # for when it replays the call through the gate.
  let(:user)     { create(:user, account: account, permissions: %w[system.infra_tasks.create system.nodes.read]) }
  let(:instance) { create(:system_node_instance, :running, account: account) }
  let(:other)    { create(:system_node_instance, :running, account: account) }

  # The shipped default: system.task.probe.node_inspect is declared auto_approve
  # and the reconciler mints that row, so the verb runs inline. With NO row the
  # gate's unmatched default is require_approval, which is not what ships.
  before { System::Governance::PolicyReconciler.new(account: account).reconcile! }

  def user_tool(u = user, acct = account)
    described_class.new(account: acct, user: u)
  end

  # A call arriving exactly as the MCP layer builds it for an mTLS node cert:
  # no User, instance_authorized set by the registrar, own node_instance carried.
  def instance_tool(own, acct = account)
    grant_inspect!(own)
    described_class.new(account: acct, user: nil).tap do |t|
      t.instance_authorized = true
      t.node_instance = own
    end
  end

  # An instance principal is authorized by tool NAME. The generic replay executor
  # re-asks that grant when it rebuilds the caller, so the fixture carries it.
  def grant_inspect!(inst)
    return if System::NodeInstancePeer.exists?(node_instance_id: inst.id)

    System::NodeInstancePeer.create!(
      node_instance: inst, account: inst.node.account, handle: "p-#{SecureRandom.hex(3)}",
      status: "active", enabled: true, trust_score: 0.5, daily_decision_budget: 10,
      granted_mcp_tools: %w[platform.system_inspect_node], granted_peer_skills: []
    )
  end

  def inspect_call(tool, **rest)
    tool.execute(params: { action: "system_inspect_node", wait_seconds: 0 }.merge(rest))
  end

  def inspect_tasks
    System::Task.where(command: "probe.node_inspect")
  end

  def complete!(task, result)
    task.update!(status: "complete", progress: 100, completed_at: Time.current,
                 events: (task.events || []) + [ { "type" => "completed", "message" => "ok", "result" => result,
                                                    "timestamp" => Time.current.iso8601 } ])
  end

  describe "the declaration" do
    let(:declaration) { described_class.declared_action("system_inspect_node") }

    # mutating: true although it never changes the node: it inserts a Task and
    # returns root diagnostics, so it must NOT land on the read-only allowlist an
    # exported agent gets (Ai::ClaudeExport::ToolAllowlist#read_action_names).
    it "is mutating (never on a read-only allowlist) but not destroy-shaped or human-only" do
      expect(declaration[:mutating]).to be true
      expect(declaration[:destructive]).to be false
      expect(declaration[:human_only]).to be false
    end

    it "is gated under the probe.node_inspect policy category on the generic replay executor" do
      expect(declaration[:action_category]).to eq("system.task.probe.node_inspect")
      expect(declaration[:action_category]).to eq("system.task.#{System::NodeInspection::COMMAND}")
      expect(declaration[:executor_class]).to eq("Ai::Executors::DeferredToolCall")
      expect(declaration[:gate_context]).to be_present
      expect(declaration[:on_proceed]).to be_present
    end

    it "is not on the read-only exported-agent allowlist" do
      registry = Ai::ClaudeExport::ToolAllowlist::Registry.snapshot
      expect(registry.registered?("system_inspect_node")).to be true
      expect(registry.read_action_names).not_to include("system_inspect_node")
      # ...while a genuine read verb still is, so the assertion above is not vacuous.
      expect(registry.read_action_names).to include("system_get_task")
    end

    it "is not among the verbs the deny overlay treats as destructive" do
      expect(::Mcp::Principal.destructive_tool?("platform.system_inspect_node")).to be false
      expect(::Mcp::Principal.destructive_tool?("system_inspect_node")).to be false
    end

    it "is registered in the tool catalog and takes the infra_tasks.create grant" do
      expect(::Ai::Tools::PlatformApiToolRegistry.all_tools["system_inspect_node"]).to eq("Ai::Tools::SystemFleetTool")
      expect(described_class::ACTION_PERMISSIONS["system_inspect_node"]).to eq("system.infra_tasks.create")
    end

    it "advertises the fixed collector enum and the scope enum, straight from the service" do
      params = described_class.action_definitions.fetch("system_inspect_node")[:parameters]
      expect(params.dig(:collector, :enum)).to eq(System::NodeInspection::COLLECTORS.keys)
      expect(params.dig(:scope, :enum)).to eq(System::NodeInspection::NFT_SCOPES)
      expect(params.dig(:collector, :required)).to be true
      expect(params.keys).not_to include(:command, :argv, :args, :sudo)
    end

    it "is governed auto_approve by default, and is NOT the approval-gated exec's category" do
      expect(System::Governance::PolicyDeclarations::MANUAL_OPERATION_DEFAULT_VERBS["probe.node_inspect"]).to eq("auto_approve")
      expect(System::Governance::PolicyDeclarations::MANUAL_OPERATION_DEFAULT_VERBS["ssh_command"]).to eq("require_approval")
    end
  end

  describe "a user principal" do
    it "queues a probe.node_inspect task on the instance, with validated options, and returns its id" do
      r = inspect_call(user_tool, instance_id: instance.id, collector: "wg_status", interface: "wg0")

      expect(r[:success]).to be true
      task = inspect_tasks.sole
      expect(task.operable).to eq(instance)
      expect(task.account).to eq(account)
      expect(task.initiated_by).to eq(user)
      expect(task.status).to eq("pending")
      expect(task.options).to eq("collector" => "wg_status", "interface" => "wg0")
      expect(r[:data]).to include(task_id: task.id, instance_id: instance.id, collector: "wg_status", status: "pending", finished: false)
    end

    it "queues every collector with exactly its declared options" do
      { "routes" => {}, "nft" => { scope: "chains" }, "journal" => { unit: "sshd.service", lines: 20 },
        "unit" => { unit: "sshd.service" }, "caps" => { unit: "sshd.service" },
        "file_stat" => { path: "/etc/hostname" } }.each do |collector, args|
        expect(inspect_call(user_tool, instance_id: instance.id, collector: collector, **args)[:success]).to be(true), collector
      end
      expect(inspect_tasks.count).to eq(6)
      expect(inspect_tasks.find_by("options->>'collector' = 'journal'").options["lines"]).to eq(20)
    end

    it "is refused a node in ANOTHER account, and creates no task" do
      foreign = create(:system_node_instance, :running, account: create(:account))

      r = inspect_call(user_tool, instance_id: foreign.id, collector: "routes")

      expect(r[:success]).to be false
      expect(inspect_tasks.count).to eq(0)
    end

    it "is denied without system.infra_tasks.create" do
      reader = create(:user, account: account, permissions: %w[system.infra_tasks.read])

      r = inspect_call(user_tool(reader), instance_id: instance.id, collector: "routes")

      expect(r[:success]).to be false
      expect(inspect_tasks.count).to eq(0)
    end

    it "requires an instance_id" do
      r = inspect_call(user_tool, collector: "routes")
      expect(r[:success]).to be false
      expect(r[:error]).to match(/instance_id/)
      expect(inspect_tasks.count).to eq(0)
    end

    it "refuses an unknown instance" do
      r = inspect_call(user_tool, instance_id: SecureRandom.uuid, collector: "routes")
      expect(r[:success]).to be false
      expect(inspect_tasks.count).to eq(0)
    end

    it "refuses a node whose instance is not running (no agent will pull the task)" do
      stopped = create(:system_node_instance, account: account, status: "terminated")

      r = inspect_call(user_tool, instance_id: stopped.id, collector: "routes")

      expect(r[:success]).to be false
      expect(r[:error]).to match(/no agent will pull|terminated/)
      expect(inspect_tasks.count).to eq(0)
    end
  end

  describe "argument validation" do
    {
      "an unknown collector"            => { collector: "ssh" },
      "a shell collector"               => { collector: "sh", command: "id" },
      "no collector"                    => { collector: nil },
      "wg all"                          => { collector: "wg_status", interface: "all" },
      "wg dump keyword"                 => { collector: "wg_status", interface: "wg0 dump" },
      "an option-shaped interface"      => { collector: "wg_status", interface: "--help" },
      "a shorthand unit"                => { collector: "journal", unit: "sshd" },
      "a globbed unit"                  => { collector: "unit", unit: "ssh*.service" },
      "a traversing unit"               => { collector: "caps", unit: "../x.service" },
      "an over-cap line count"          => { collector: "journal", unit: "a.service", lines: 501 },
      "a zero line count"               => { collector: "journal", unit: "a.service", lines: 0 },
      "a bad nft scope"                 => { collector: "nft", scope: "flush ruleset" },
      "a traversing path"               => { collector: "file_stat", path: "/etc/../etc/shadow" },
      "a relative path"                 => { collector: "file_stat", path: "etc/hostname" },
      "proc environ"                    => { collector: "file_stat", path: "/proc/1/environ" },
      "shadow"                          => { collector: "file_stat", path: "/etc/shadow" },
      "a private-key directory"         => { collector: "file_stat", path: "/persist/var/lib/powernode/pki/node.key" },
      "a foreign argument"              => { collector: "routes", path: "/etc/hostname" }
    }.each do |name, args|
      it "refuses #{name} before any task exists" do
        r = inspect_call(user_tool, instance_id: instance.id, **args)

        expect(r[:success]).to be false
        expect(inspect_tasks.count).to eq(0)
      end
    end
  end

  describe "the SELF-ONLY rule for an instance principal" do
    it "lets an instance inspect ITSELF" do
      r = inspect_call(instance_tool(instance), instance_id: instance.id, collector: "routes")

      expect(r[:success]).to be true
      task = inspect_tasks.sole
      expect(task.operable).to eq(instance)
      expect(task.initiated_by).to be_nil
    end

    it "lets an instance omit instance_id, meaning itself" do
      r = inspect_call(instance_tool(instance), collector: "nft")

      expect(r[:success]).to be true
      expect(inspect_tasks.sole.operable).to eq(instance)
    end

    it "REFUSES an instance inspecting ANOTHER instance of the same account, and creates no task" do
      r = inspect_call(instance_tool(instance), instance_id: other.id, collector: "routes")

      expect(r[:success]).to be false
      expect(r[:error]).to match(/OWN|itself|own node/i)
      expect(inspect_tasks.count).to eq(0)
    end

    it "refuses a cross-instance attempt for EVERY collector (the rule is not per-collector)" do
      { "wg_status" => { interface: "wg0" }, "routes" => {}, "nft" => {}, "journal" => { unit: "a.service" },
        "unit" => { unit: "a.service" }, "caps" => { unit: "a.service" }, "file_stat" => { path: "/etc/hostname" } }
        .each do |collector, args|
        r = inspect_call(instance_tool(instance), instance_id: other.id, collector: collector, **args)
        expect(r[:success]).to be(false), collector
      end
      expect(inspect_tasks.count).to eq(0)
    end

    it "refuses an instance inspecting an instance of another ACCOUNT" do
      foreign = create(:system_node_instance, :running, account: create(:account))

      r = inspect_call(instance_tool(instance), instance_id: foreign.id, collector: "routes")

      expect(r[:success]).to be false
      expect(inspect_tasks.count).to eq(0)
    end

    it "refuses a restricted principal that carries no node identity (a federation partner)" do
      tool = described_class.new(account: account, user: nil).tap { |t| t.instance_authorized = true }

      r = inspect_call(tool, instance_id: instance.id, collector: "routes")

      expect(r[:success]).to be false
      expect(inspect_tasks.count).to eq(0)
    end

    it "keys the rule on the principal, not the verb: the same refusal holds when the target is named by id string variations" do
      [ other.id.to_s, other.id.to_s.upcase, " #{other.id} " ].each do |id|
        r = inspect_call(instance_tool(instance), instance_id: id, collector: "routes")
        expect(r[:success]).to be false
      end
      expect(inspect_tasks.count).to eq(0)
    end

    it "records a refused cross-instance attempt as a fleet event, so the attempt is queryable" do
      expect { inspect_call(instance_tool(instance), instance_id: other.id, collector: "routes") }
        .to change { System::FleetEvent.where(kind: "system.mcp_node_inspect_refused").count }.by(1)

      event = System::FleetEvent.where(kind: "system.mcp_node_inspect_refused").last
      expect(event.payload).to include("caller_instance_id" => instance.id, "target_instance_id" => other.id)
    end

    it "does NOT restrict a user principal to one instance (the opposite direction)" do
      expect(inspect_call(user_tool, instance_id: other.id, collector: "routes")[:success]).to be true
      expect(inspect_call(user_tool, instance_id: instance.id, collector: "routes")[:success]).to be true
    end

    it "still validates arguments for an instance inspecting itself" do
      r = inspect_call(instance_tool(instance), instance_id: instance.id, collector: "file_stat", path: "/etc/shadow")

      expect(r[:success]).to be false
      expect(inspect_tasks.count).to eq(0)
    end
  end

  describe "waiting for the result" do
    before { travel_to(Time.current.change(usec: 0)) }
    after { travel_back }

    # any_instance: through the gate the wait runs on the tool the generic replay
    # executor REBUILDS, not the one the test holds.
    def stub_sleep(_tool = nil, &on_tick)
      @sleeps = []
      allow_any_instance_of(described_class).to receive(:sleep) do |_inst, seconds|
        @sleeps << seconds
        travel(seconds.seconds)
        on_tick&.call(@sleeps.size)
      end
    end

    it "returns the task id at once, unwaited, for wait_seconds 0" do
      tool = user_tool
      stub_sleep(tool)

      r = inspect_call(tool, instance_id: instance.id, collector: "routes", wait_seconds: 0)

      expect(r[:data]).to include(status: "pending", finished: false)
      expect(r[:data]).not_to have_key(:result)
      expect(r[:data]).not_to have_key(:timed_out)
      expect(@sleeps).to be_empty
    end

    it "waits for the agent and returns the collector's result when the task completes mid-wait" do
      tool = user_tool
      stub_sleep(tool) do |tick|
        next unless tick == 2

        complete!(inspect_tasks.sole, "collector" => "routes", "ok" => true,
                                      "sections" => [ { "name" => "ip vrf show", "ok" => true, "output" => "vrf-mgmt 10\n", "truncated" => false } ])
      end

      r = inspect_call(tool, instance_id: instance.id, collector: "routes", wait_seconds: 30)

      expect(r[:success]).to be true
      expect(r[:data]).to include(status: "complete", finished: true, timed_out: false)
      expect(r[:data][:result]["collector"]).to eq("routes")
      expect(r[:data][:result]["sections"].first["output"]).to include("vrf-mgmt")
      expect(@sleeps).to eq([ 2, 2 ])
    end

    it "defaults to a wait (the verb exists to wait), capped at the server limit" do
      tool = user_tool
      stub_sleep(tool)

      r = tool.execute(params: { action: "system_inspect_node", instance_id: instance.id, collector: "routes" })

      expect(r[:data]).to include(timed_out: true, wait_seconds: described_class::WAIT_MAX_SECONDS, finished: false)
      expect(@sleeps.sum).to be >= described_class::WAIT_MAX_SECONDS
    end

    it "times out as a SUCCESS carrying the task id, so the caller can keep waiting with system_get_task" do
      tool = user_tool
      stub_sleep(tool)

      r = inspect_call(tool, instance_id: instance.id, collector: "routes", wait_seconds: 4)

      expect(r[:success]).to be true
      expect(r[:data]).to include(timed_out: true, wait_seconds: 4, status: "pending", task_id: inspect_tasks.sole.id)
    end

    it "refuses a wait_seconds that is not an integer, creating no task" do
      r = inspect_call(user_tool, instance_id: instance.id, collector: "routes", wait_seconds: "soon")

      expect(r[:success]).to be false
      expect(inspect_tasks.count).to eq(0)
    end

    it "reports an agent-side refusal as an error carrying the task id and the (redacted) reason" do
      tool = user_tool
      stub_sleep(tool) do |tick|
        inspect_tasks.sole.update_columns(status: "failed", error_message: "probe.node_inspect: taskguard: refused: unit: is not a unit on this node (token=abcd1234efgh)") if tick == 1
      end

      r = inspect_call(tool, instance_id: instance.id, collector: "unit", unit: "ghost.service", wait_seconds: 10)

      expect(r[:success]).to be false
      expect(r[:error]).to include("is not a unit on this node")
      expect(r[:error]).not_to include("abcd1234efgh")
      expect(r[:task_id]).to eq(inspect_tasks.sole.id)
    end

    # The agent scrubs on the node, but this surface serves stored node output
    # to an agent or operator, so it redacts again, exactly as system_get_task
    # does for events.
    it "redacts the stored result on the way out, whatever the agent sent" do
      tool = user_tool
      stub_sleep(tool) do |tick|
        complete!(inspect_tasks.sole, "collector" => "unit", "ok" => true, "unit" => "app.service",
                                      "sections" => [ { "name" => "cat", "ok" => true, "truncated" => false,
                                                        "output" => "Environment=DB_PASSWORD=hunter2hunter2\npassword=hunter2hunter2\nExecStart=/usr/bin/app\n" } ]) if tick == 1
      end

      r = inspect_call(tool, instance_id: instance.id, collector: "unit", unit: "app.service", wait_seconds: 10)

      text = r[:data][:result].to_json
      expect(text).not_to include("hunter2hunter2")
      expect(text).to include("ExecStart=/usr/bin/app")
    end

    it "keeps a sha256, mtime and mode intact through the redaction" do
      tool = user_tool
      sha = "a" * 64
      stub_sleep(tool) do |tick|
        complete!(inspect_tasks.sole, "collector" => "file_stat", "ok" => true, "exists" => true, "type" => "file",
                                      "path" => "/etc/hostname", "resolved_path" => "/etc/hostname", "size" => 5,
                                      "mode" => "0644", "mtime" => "2026-09-01T12:30:00Z", "sha256" => sha) if tick == 1
      end

      r = inspect_call(tool, instance_id: instance.id, collector: "file_stat", path: "/etc/hostname", wait_seconds: 10)

      expect(r[:data][:result]).to include("sha256" => sha, "mode" => "0644", "mtime" => "2026-09-01T12:30:00Z", "size" => 5)
    end

    it "keeps a wireguard PUBLIC key and the peer lines of a wg_status result" do
      tool = user_tool
      pub = "#{'Q' * 43}="
      stub_sleep(tool) do |tick|
        complete!(inspect_tasks.sole, "collector" => "wg_status", "ok" => true, "interface" => "wg0",
                                      "sections" => [ { "name" => "wg show wg0", "ok" => true, "truncated" => false,
                                                        "output" => "interface: wg0\n  listening port: 51820\n\npeer: #{pub}\n  endpoint: 192.0.2.10:51820\n" } ]) if tick == 1
      end

      r = inspect_call(tool, instance_id: instance.id, collector: "wg_status", interface: "wg0", wait_seconds: 10)

      out = r[:data][:result]["sections"].first["output"]
      expect(out).to include("listening port: 51820", "endpoint: 192.0.2.10:51820", pub)
    end
  end

  # IMP-52762a704a3d review round: the MCP door goes through the SAME policy row
  # the REST task-creation gate reads. Before, this verb inserted the Task
  # directly, so an operator tightening system.task.probe.node_inspect changed
  # nothing for an agent calling it over MCP.
  describe "governance on the MCP path" do
    def put_policy!(verb)
      Ai::InterventionPolicy.where(account: account, action_category: "system.task.probe.node_inspect").delete_all
      Ai::InterventionPolicy.create!(
        account: account, action_category: "system.task.probe.node_inspect",
        scope: "global", ai_agent_id: nil, user_id: nil, policy: verb, priority: 5,
        is_active: true, conditions: {}, preferred_channels: %w[notification]
      )
    end

    def deferred
      ::Ai::DeferredOperation.where(account_id: account.id).order(created_at: :desc)
    end

    it "runs inline under the shipped auto_approve row, and parks nothing pending" do
      row = Ai::InterventionPolicy.find_by(account: account, action_category: "system.task.probe.node_inspect", scope: "global", ai_agent_id: nil)
      expect(row&.policy).to eq("auto_approve")

      r = inspect_call(user_tool, instance_id: instance.id, collector: "routes")

      expect(r[:success]).to be true
      expect(r[:data]).not_to have_key(:pending)
      expect(inspect_tasks.count).to eq(1)
      expect(deferred.pluck(:status)).not_to include("pending")
    end

    it "REFUSES under a block row, and queues nothing" do
      put_policy!("block")

      r = inspect_call(user_tool, instance_id: instance.id, collector: "routes")

      expect(r[:success]).to be false
      expect(r[:error]).to be_present
      expect(inspect_tasks.count).to eq(0)
    end

    it "returns the pending envelope under require_approval, queueing nothing until approved" do
      put_policy!("require_approval")

      r = nil
      expect { r = inspect_call(user_tool, instance_id: instance.id, collector: "wg_status", interface: "wg0") }
        .to change(::Ai::DeferredOperation, :count).by(1)

      expect(r[:success]).to be true
      expect(r[:data][:pending]).to be true
      expect(r[:data][:action_category]).to eq("system.task.probe.node_inspect")
      expect(r[:data][:deferred_operation_id]).to eq(deferred.first.id)
      expect(inspect_tasks.count).to eq(0)
      expect(deferred.first.source_id).to eq(instance.id)
    end

    it "really inspects when the parked operation is approved (the verb still works)" do
      put_policy!("require_approval")
      inspect_call(user_tool, instance_id: instance.id, collector: "wg_status", interface: "wg0", wait_seconds: 0)

      deferred.first.execute_now!

      task = inspect_tasks.sole
      expect(task.operable).to eq(instance)
      expect(task.options).to eq("collector" => "wg_status", "interface" => "wg0")
    end

    it "gates an instance principal too, and it still inspects only itself when approved" do
      put_policy!("require_approval")

      r = inspect_call(instance_tool(instance), collector: "routes")
      expect(r[:data][:pending]).to be true
      expect(inspect_tasks.count).to eq(0)

      deferred.first.execute_now!
      expect(inspect_tasks.sole.operable).to eq(instance)
    end

    it "blocks an instance principal under a block row" do
      put_policy!("block")

      r = inspect_call(instance_tool(instance), collector: "routes")

      expect(r[:success]).to be false
      expect(inspect_tasks.count).to eq(0)
    end

    # A call that could only ever be refused must keep its inline error, not park
    # an approval an operator then has to dispose of.
    it "parks nothing for a call it would refuse anyway" do
      put_policy!("require_approval")
      stopped = create(:system_node_instance, account: account, status: "stopped")

      [ { instance_id: other.id, collector: "ssh" },
        { instance_id: instance.id, collector: "file_stat", path: "/etc/shadow" },
        { instance_id: instance.id, collector: "wg_status", interface: "all" },
        { instance_id: stopped.id, collector: "routes" },
        { instance_id: SecureRandom.uuid, collector: "routes" },
        { collector: "routes" } ].each do |args|
        r = inspect_call(user_tool, **args)
        expect(r[:success]).to be(false), args.inspect
      end
      r = inspect_call(instance_tool(instance), instance_id: other.id, collector: "routes")
      expect(r[:success]).to be false
      expect(deferred.count).to eq(0)
      expect(inspect_tasks.count).to eq(0)
    end
  end

  describe "refusal text" do
    it "answers an unknown instance with a literal message that carries no account id and no SQL" do
      r = inspect_call(user_tool, instance_id: SecureRandom.uuid, collector: "routes")

      expect(r[:success]).to be false
      expect(r[:error]).to match(/Couldn't find System::NodeInstance/)
      expect(r[:error]).not_to include(account.id)
      expect(r[:error]).not_to match(/WHERE|SELECT|account_id|"system_node_instances"/i)
    end

    it "answers a foreign account's instance identically to an unknown one" do
      foreign = create(:system_node_instance, :running, account: create(:account))

      r = inspect_call(user_tool, instance_id: foreign.id, collector: "routes")

      expect(r[:error]).to match(/Couldn't find System::NodeInstance/)
      expect(r[:error]).not_to include(account.id)
    end
  end

  describe "the node must be running" do
    %w[stopped stopping pending provisioning rebooting terminated].each do |status|
      it "refuses a #{status} instance, which would otherwise take the task whenever it next boots" do
        inst = create(:system_node_instance, account: account, status: status)

        r = inspect_call(user_tool, instance_id: inst.id, collector: "routes")

        expect(r[:success]).to be false
        expect(r[:error]).to match(/#{status}/)
        expect(inspect_tasks.count).to eq(0)
      end
    end

    it "accepts running and starting" do
      %w[running starting].each do |status|
        inst = create(:system_node_instance, account: account, status: status)
        expect(inspect_call(user_tool, instance_id: inst.id, collector: "routes")[:success]).to be(true), status
      end
    end
  end
end
