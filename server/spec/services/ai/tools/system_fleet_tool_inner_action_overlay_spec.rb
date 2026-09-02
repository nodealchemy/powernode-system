# frozen_string_literal: true

require "rails_helper"

# IMP-e89d83547bad — the deny overlay must see the action that ACTUALLY runs,
# even when the tool routes on its own key instead of :action.
#
# An instance principal (mTLS node cert, no User) is authorized by TOOL NAME:
# Mcp::Principal#may_invoke? checks the grant globs and the DESTRUCTIVE_TOOL_
# PATTERNS deny overlay against that name, McpPlatformToolRegistrar#
# enforce_action_scope! pins params[:action] to it, and Ai::Tools::BaseTool#
# enforce_instance_deny_overlay! re-arms the overlay on every hop.
#
# All three read the SAME key. SystemFleetTool's two lifecycle-skill wrappers
# do not: `action:` is owned by the MCP dispatcher (it carries the tool name),
# so they discriminate on `op:` (aliases `maintenance_action:` /
# `resilience_action:`). Nothing pinned that key, and BaseTool#
# effective_action_name never read it — so an instance granted the benign
# composer name reached a destroy-shaped op:
#
#   platform.system_platform_resilience  + op: "drain_instance"  (*drain_*)
#   platform.system_platform_maintenance + op: "cert_rotate"     (*rotate*)
#
# Both would be refused outright had they arrived as tool names. Neither
# executor nests a tool — PlatformResilienceExecutor and
# PlatformMaintenanceExecutor mutate models/services directly — so the
# nested-depth re-arm (IMP-0e6b216de843) can never reach them. This is a
# FIRST-HOP gap, and the sharpest edge is drain_instance: since
# IMP-8c0f0fe9a8cf it cordons and STOPS the instance through
# System::InstanceControlService, attributed to `@user&.id` — nil for an
# instance principal. An unattributed stop of a fleet node is exactly the
# destructive action the overlay exists to prevent.
RSpec.describe "instance principal → SystemFleetTool inner-action ops" do
  let(:account) { create(:account) }
  let(:node_instance) { double("NodeInstance", id: SecureRandom.uuid, account: account) }

  # The grant an operator would actually write: the benign composer name, and
  # nothing else. Both names are non-destroy-shaped, so may_invoke? clears them.
  let(:granted_names) do
    %w[platform.system_platform_resilience platform.system_platform_maintenance]
  end

  # Save/restore rather than Mcp::Principal.reset! — reset! also clears
  # instance_resolver, which the system extension's engine injects once at boot.
  around do |example|
    previous = ::Mcp::Principal.tool_grant_resolver
    ::Mcp::Principal.tool_grant_resolver = ->(_i) { granted_names }
    example.run
    ::Mcp::Principal.tool_grant_resolver = previous
  end

  let(:principal) do
    ::Mcp::Principal.new(kind: :instance, account: account,
                         node_instance: node_instance, subject_id: node_instance.id)
  end

  # Post-construction provenance injection, mirroring what
  # McpPlatformToolRegistrar#execute_tool does for an instance principal.
  def instance_tool
    tool = ::Ai::Tools::SystemFleetTool.new(account: account, user: nil)
    tool.instance_authorized = true
    tool.node_instance = node_instance
    tool
  end

  # Params arrive from the registrar as a HashWithIndifferentAccess; use the
  # same shape here so the key lookup is exercised the way production does it.
  def invoke_as_instance(**params)
    instance_tool.execute(params: params.with_indifferent_access)
  end

  let(:executor_spy_class) do
    Class.new do
      attr_accessor :instance_authorized, :node_instance
      attr_reader :calls

      def initialize(**) = @calls = []

      def execute(**kwargs)
        @calls << kwargs
        { success: true, data: { ok: true } }
      end
    end
  end

  # ── What the first hop actually cleared ──────────────────────────────────
  describe "the grant the operator wrote" do
    it "permits both composer names and refuses the ops they can reach by name" do
      granted_names.each { |n| expect(principal.may_invoke?(n)).to be true }

      # The same work, named as a tool, is refused unconditionally — this is
      # the authorization the op: key routes around.
      expect(::Mcp::Principal.destructive_tool?("drain_instance")).to be true
      expect(::Mcp::Principal.destructive_tool?("cert_rotate")).to be true
    end
  end

  # ── The gap: destroy-shaped ops reached through the inner key ────────────
  describe "destroy-shaped inner ops" do
    {
      "system_platform_resilience"  => { op: "drain_instance",
                                         executor: ::System::Ai::Skills::PlatformResilienceExecutor },
      "system_platform_maintenance" => { op: "cert_rotate",
                                         executor: ::System::Ai::Skills::PlatformMaintenanceExecutor }
    }.each do |action, spec|
      it "refuses #{action} carrying op #{spec[:op].inspect}" do
        spy = executor_spy_class.new
        allow(spec[:executor]).to receive(:new).and_return(spy)

        expect {
          invoke_as_instance(action: action, op: spec[:op])
        }.to raise_error(::Mcp::ProtocolService::PermissionDeniedError, /destroy-shaped/i)

        # The refusal is BEFORE the work, not a rollback after it.
        expect(spy.calls).to be_empty
      end

      it "refuses #{action} under a maximally permissive grant too" do
        ::Mcp::Principal.tool_grant_resolver = ->(_i) { [ "platform.*" ] }
        allow(spec[:executor]).to receive(:new).and_return(executor_spy_class.new)

        expect {
          invoke_as_instance(action: action, op: spec[:op])
        }.to raise_error(::Mcp::ProtocolService::PermissionDeniedError)
      end
    end

    # The wrappers accept a per-skill alias for the inner key. A fence that
    # only knew `op:` would be one rename away from useless.
    it "refuses the resilience_action: alias for drain_instance" do
      allow(::System::Ai::Skills::PlatformResilienceExecutor).to receive(:new)
        .and_return(executor_spy_class.new)

      expect {
        invoke_as_instance(action: "system_platform_resilience", resilience_action: "drain_instance")
      }.to raise_error(::Mcp::ProtocolService::PermissionDeniedError, /destroy-shaped/i)
    end

    it "refuses the maintenance_action: alias for cert_rotate" do
      allow(::System::Ai::Skills::PlatformMaintenanceExecutor).to receive(:new)
        .and_return(executor_spy_class.new)

      expect {
        invoke_as_instance(action: "system_platform_maintenance", maintenance_action: "cert_rotate")
      }.to raise_error(::Mcp::ProtocolService::PermissionDeniedError, /destroy-shaped/i)
    end

    # The sharpest edge, against real production code and a real row.
    #
    # This used to assert the absence of the `drain_*` config markers. Since
    # IMP-8c0f0fe9a8cf (APO-3b) the branch writes no markers at ALL, so that
    # assertion would pass whether or not the overlay fired — an absence oracle
    # the change under test had quietly emptied. What the overlay now has to
    # prevent is the real thing: an unattributed STOP. Assert the lifecycle
    # choke point was never reached and the row never left `running`.
    it "leaves the instance running and never reaches the lifecycle service" do
      target = create(:system_node_instance, account: account, status: "running")
      allow(::System::InstanceControlService).to receive(:execute)

      expect {
        invoke_as_instance(action: "system_platform_resilience",
                           op: "drain_instance", instance_id: target.id)
      }.to raise_error(::Mcp::ProtocolService::PermissionDeniedError)

      expect(::System::InstanceControlService).not_to have_received(:execute)
      expect(target.reload.status).to eq("running")
    end
  end

  # ── Composition must keep working ────────────────────────────────────────
  #
  # The operator granted these composers to do their job. Refusing the whole
  # tool instead of the destroy-shaped op would be an outage, not a fix.
  describe "benign inner ops stay permitted for the same instance" do
    {
      "system_platform_resilience" => {
        executor: ::System::Ai::Skills::PlatformResilienceExecutor,
        ops: %w[failover_check scale]
      },
      "system_platform_maintenance" => {
        executor: ::System::Ai::Skills::PlatformMaintenanceExecutor,
        ops: %w[cert_status drift_check health_check]
      }
    }.each do |action, spec|
      spec[:ops].each do |op|
        it "runs #{action} op #{op.inspect}" do
          spy = executor_spy_class.new
          allow(spec[:executor]).to receive(:new).and_return(spy)

          result = invoke_as_instance(action: action, op: op)

          expect(result[:success]).to be true
          expect(spy.calls.first[:action]).to eq(op)
          # Provenance still reaches the executor (IMP-0e6b216de843).
          expect(spy.instance_authorized).to be true
        end
      end
    end
  end

  # ── The regression that matters: USER principals are untouched ───────────
  #
  # The overlay has never applied to users — destructive work is theirs, run
  # through has_permission? and eligible for approval gating. Pinned at EVERY
  # op, including the two destroy-shaped ones.
  describe "user principals" do
    # `system.instances.control` is NOT decoration. Since IMP-8c0f0fe9a8cf the
    # drain branch stops the instance through System::InstanceControlService,
    # and the executor gates that on the grant `system_stop_instance` itself
    # requires rather than on the skill's coarser `system.platform.scale`
    # entry-point mapping. A user holding only the entry-point grant is refused
    # by the executor (pinned in platform_resilience_executor_spec.rb); this
    # file is about the OVERLAY, so its operator holds what the drain needs.
    let(:operator) do
      create(:user, account: account,
                    permissions: %w[system.platform.read system.platform.scale
                                    system.instances.control])
    end

    {
      "system_platform_resilience" => {
        executor: ::System::Ai::Skills::PlatformResilienceExecutor,
        ops: %w[drain_instance scale failover_check]
      },
      "system_platform_maintenance" => {
        executor: ::System::Ai::Skills::PlatformMaintenanceExecutor,
        ops: %w[cert_status cert_rotate drift_check health_check]
      }
    }.each do |action, spec|
      spec[:ops].each do |op|
        it "runs #{action} op #{op.inspect} for a user" do
          spy = executor_spy_class.new
          allow(spec[:executor]).to receive(:new).and_return(spy)

          result = ::Ai::Tools::SystemFleetTool
                     .new(account: account, user: operator)
                     .execute(params: { action: action, op: op }.with_indifferent_access)

          expect(result[:success]).to be true
          expect(spy.calls.first[:action]).to eq(op)
          # Never marked — the overlay's guard clause must not fire for a user.
          expect(spy.instance_authorized).to be_nil
        end
      end
    end

    # End to end against production code: a user's drain really drains, and is
    # attributed to them.
    #
    # IMP-8c0f0fe9a8cf (APO-3b) changed what "really drains" MEANS. It used to
    # assert the three config.drain_* markers, which is what the branch wrote
    # when it stopped nothing; drain now cordons and STOPS through
    # System::InstanceControlService, and the attribution rides on the
    # FleetEvent instead of on a config key nothing read. Only the lifecycle
    # call is stubbed — this file is about the instance-principal overlay, not
    # about provider adapters.
    it "lets a user drain an instance for real, attributed" do
      target = create(:system_node_instance, account: account, status: "running")
      allow(::System::InstanceControlService).to receive(:execute)
        .and_return(::System::Runtime::Result.ok(data: { status: "stopped" }))

      result = ::Ai::Tools::SystemFleetTool
                 .new(account: account, user: operator)
                 .execute(params: { action: "system_platform_resilience",
                                    op: "drain_instance", instance_id: target.id }
                            .with_indifferent_access)

      expect(result[:success]).to be true
      expect(::System::InstanceControlService).to have_received(:execute)
        .with(instance: an_object_having_attributes(id: target.id), action: :stop)
      event = ::System::FleetEvent.find_by(kind: "platform.resilience.drain_started",
                                           node_instance_id: target.id)
      expect(event&.payload&.dig("by_user")).to eq(operator.id)
    end
  end

  # ── The reconciler path this must not break ─────────────────────────────
  #
  # System::Fleet::DecisionEngine builds tools with user: nil and genuinely
  # means "trusted in-process caller" — no instance provenance, so the overlay
  # never engages.
  describe "in-process caller (internal: true, no provenance)" do
    it "still runs the destroy-shaped op" do
      target = create(:system_node_instance, account: account, status: "running")
      allow(::System::InstanceControlService).to receive(:execute)
        .and_return(::System::Runtime::Result.ok(data: { status: "stopped" }))

      result = ::Ai::Tools::SystemFleetTool
                 .new(account: account, user: nil, internal: true)
                 .execute(params: { action: "system_platform_resilience",
                                    op: "drain_instance", instance_id: target.id }
                            .with_indifferent_access)

      expect(result[:success]).to be true
      expect(::System::InstanceControlService).to have_received(:execute)
        .with(instance: an_object_having_attributes(id: target.id), action: :stop)
      event = ::System::FleetEvent.find_by(kind: "platform.resilience.drain_started",
                                           node_instance_id: target.id)
      expect(event&.payload&.dig("by_user")).to be_nil
    end
  end

  # ── Durability: the fence must cover every inner-action key that exists ──
  #
  # Two wrappers route on their own key today; a third added the same way
  # would be silently uncovered, which is exactly how this gap opened. The
  # idiom is `op = params[...]`, so scan for it and require every key it reads
  # to be one the override checks.
  describe "every inner-action routing key is covered" do
    let(:source_path) do
      Rails.root.join("../extensions/system/server/app/services/ai/tools/system_fleet_tool.rb")
    end

    it "finds no op-routing key outside INNER_ACTION_KEYS" do
      covered = ::Ai::Tools::SystemFleetTool::INNER_ACTION_KEYS.map(&:to_s)
      expect(covered).not_to be_empty

      routing_lines = File.readlines(source_path).each_with_index.select do |line, _i|
        !line.strip.start_with?("#") && line.match?(/\bop\s*=\s*params\[/)
      end
      expect(routing_lines).not_to be_empty

      uncovered = routing_lines.flat_map do |line, i|
        line.scan(/params\[[:"]([a-z_]+)"?\]/).flatten
            .reject { |key| covered.include?(key) }
            .map { |key| "system_fleet_tool.rb:#{i + 1}: params[:#{key}]" }
      end

      expect(uncovered).to be_empty, <<~MSG
        These route an inner action on a key the deny overlay never name-checks,
        so an instance principal granted the tool name reaches whatever they
        route to — the IMP-e89d83547bad gap, reopened. Add the key to
        Ai::Tools::SystemFleetTool::INNER_ACTION_KEYS:

        #{uncovered.join("\n")}
      MSG
    end
  end
end
