# frozen_string_literal: true

require "rails_helper"

# IMP-0e6b216de843 — the hop BENEATH the first-hop ladder.
#
# An instance principal (mTLS node cert, no User) is authorized by TOOL NAME:
# the streamable controller runs Mcp::Principal#may_invoke?(name) — grant globs
# plus the DESTRUCTIVE_TOOL_PATTERNS deny overlay — and McpPlatformToolRegistrar
# marks the call `instance_authorized`. Tools that delegate to a skill executor
# (SdwanTool#run_skill_executor, SystemIngressTool#run_executor) forwarded only
# `user: @user` — nil for an instance — so BaseSkillExecutor#tool derived
# `internal: @user.nil?` and handed EVERY nested tool the in-process bypass at
# the first rung of its own ladder. Two distinct losses:
#
#   1. name scope — a grant for ONE tool name became a trusted caller for every
#      tool the executor nests.
#   2. the deny overlay — may_invoke? only ever sees the FIRST name, so a nested
#      tool is never name-checked, and "deny wins over any grant" stopped being
#      true one hop down.
#
# `internal: @user.nil?` is CORRECT for a reconciler (System::Fleet::DecisionEngine
# builds executors with user: nil and genuinely means "in-process"). The fix is
# to make the two distinguishable — carry the instance provenance — not to drop
# the internal path.
RSpec.describe "instance principal → nested skill executor → tool" do
  let(:account) { create(:account) }

  # The instance's grant: ONE benign, non-destroy-shaped tool name.
  let(:granted_name) { "platform.system_expose_service_publicly" }

  let(:node_instance) { double("NodeInstance", id: SecureRandom.uuid, account: account) }

  # Save/restore rather than Mcp::Principal.reset! — reset! also clears
  # instance_resolver, which the system extension's engine injects once at boot.
  around do |example|
    previous = ::Mcp::Principal.tool_grant_resolver
    ::Mcp::Principal.tool_grant_resolver = ->(_i) { [ granted_name ] }
    example.run
    ::Mcp::Principal.tool_grant_resolver = previous
  end

  let(:principal) do
    ::Mcp::Principal.new(kind: :instance, account: account,
                         node_instance: node_instance, subject_id: node_instance.id)
  end

  # ── The authorization the first hop actually granted ─────────────────────
  describe "what the grant authorizes at the first hop" do
    it "permits the granted name and refuses everything else it might nest" do
      expect(principal.may_invoke?(granted_name)).to be true

      # A different tool name — never granted.
      expect(principal.may_invoke?("platform.system_sdwan_create_virtual_ip")).to be false

      # Destroy-shaped — refused even if it HAD been granted (deny overlay).
      expect(principal.may_invoke?("platform.system_delete_architecture")).to be false
    end

    it "refuses a destroy-shaped name under a maximally permissive grant" do
      ::Mcp::Principal.tool_grant_resolver = ->(_i) { [ "platform.*" ] }

      expect(principal.may_invoke?("platform.system_delete_architecture")).to be false
    end
  end

  # ── 1. The hop: does the executor learn it is serving an instance? ───────
  #
  # Provenance is injected post-construction (mirroring how
  # McpPlatformToolRegistrar marks a tool), so these assert on what the routed
  # executor ENDS UP carrying, not on `.new`'s argument list — the constructor
  # contract is deliberately unchanged.
  let(:executor_spy) do
    Class.new do
      attr_accessor :instance_authorized, :node_instance
      attr_reader :constructor_kwargs

      def initialize(**kwargs) = @constructor_kwargs = kwargs
      def execute(**) = { success: true, data: {} }
    end
  end

  describe "SystemIngressTool#run_executor" do
    it "hands the executor the instance provenance" do
      spy = executor_spy.new
      allow(::System::Ai::Skills::ExposeServicePubliclyExecutor).to receive(:new).and_return(spy)

      tool = ::Ai::Tools::SystemIngressTool.new(account: account, user: nil)
      tool.instance_authorized = true
      tool.node_instance = node_instance
      tool.execute(params: { action: "system_expose_service_publicly", hostname: "x.example.com" })

      expect(spy.instance_authorized).to be true
      expect(spy.node_instance).to eq(node_instance)
    end

    it "leaves a user-principal call's executor unmarked" do
      spy = executor_spy.new
      allow(::System::Ai::Skills::ExposeServicePubliclyExecutor).to receive(:new).and_return(spy)

      operator = create(:user, account: account, permissions: %w[system.ingress.manage])
      tool = ::Ai::Tools::SystemIngressTool.new(account: account, user: operator)
      tool.execute(params: { action: "system_expose_service_publicly", hostname: "x.example.com" })

      expect(spy.instance_authorized).to be_nil
      expect(spy.node_instance).to be_nil
    end
  end

  describe "SdwanTool#run_skill_executor" do
    it "hands the executor the instance provenance" do
      spy = executor_spy.new
      allow(::System::Ai::Skills::SdwanFederationComposeExecutor).to receive(:new).and_return(spy)

      tool = ::Ai::Tools::SdwanTool.new(account: account, user: nil)
      tool.instance_authorized = true
      tool.node_instance = node_instance
      tool.execute(params: { action: "system_sdwan_federation_compose", network_name: "n", dry_run: true })

      expect(spy.instance_authorized).to be true
      expect(spy.node_instance).to eq(node_instance)
    end
  end

  # SystemFleetTool builds executors at SEVEN sites rather than through one
  # router, and every one of them dropped the provenance the same way. These
  # two nest a tool today (RunbookGenerateExecutor -> system_get_template,
  # CveResponseExecutor -> system_list_modules); the other five are the same
  # latent shape. None of the seven fails closed earlier — they pass the tool's
  # own `@account`, not a user-derived one, so an instance reaches them.
  describe "SystemFleetTool executor sites" do
    {
      "system_runbook_generate" => ::System::Ai::Skills::RunbookGenerateExecutor,
      "system_cve_triage"       => ::System::Ai::Skills::CveResponseExecutor,
      "system_attribute_failure" => ::System::Ai::Skills::AttributeFailureExecutor,
      "system_platform_maintenance" => ::System::Ai::Skills::PlatformMaintenanceExecutor,
      "system_platform_resilience"  => ::System::Ai::Skills::PlatformResilienceExecutor
    }.each do |action, executor_class|
      it "hands #{executor_class.name.demodulize} the instance provenance" do
        spy = executor_spy.new
        allow(executor_class).to receive(:new).and_return(spy)

        tool = ::Ai::Tools::SystemFleetTool.new(account: account, user: nil)
        tool.instance_authorized = true
        tool.node_instance = node_instance
        tool.execute(params: { action: action, op: "health_check", template_id: SecureRandom.uuid,
                               cve_id: "CVE-2026-0001", instance_id: SecureRandom.uuid })

        expect(spy.instance_authorized).to be true
        expect(spy.node_instance).to eq(node_instance)
      end
    end
  end

  # The structural guarantee behind all of the above. Three tools dropped the
  # provenance independently, so "remember to mark it" is not a control — the
  # only durable one is that no tool constructs a skill executor except through
  # Ai::Tools::BaseTool#build_skill_executor. An eighth site fails HERE.
  describe "no tool builds a skill executor outside the funnel" do
    let(:tool_sources) do
      Dir[Rails.root.join("../extensions/system/server/app/services/ai/tools/**/*.rb")]
    end

    it "finds every extension tool routing through build_skill_executor" do
      expect(tool_sources).not_to be_empty

      offenders = tool_sources.flat_map do |path|
        File.readlines(path).each_with_index.filter_map do |line, i|
          next if line.strip.start_with?("#")
          # Literal (`Skills::FooExecutor.new(`) and constantized
          # (`klass.new(`, `executor_class.new(`) construction alike.
          next unless line.match?(/Skills::\w+Executor\s*\.new\(/) ||
                      line.match?(/\b(klass|executor_class|executor)\.new\(/)

          "#{path.split('/').last}:#{i + 1}: #{line.strip}"
        end
      end

      expect(offenders).to be_empty, <<~MSG
        These build a skill executor directly instead of via
        Ai::Tools::BaseTool#build_skill_executor, so an MCP instance principal's
        provenance is dropped and every tool the executor nests is built
        `internal: true` — the IMP-0e6b216de843 bypass, reopened:

        #{offenders.join("\n")}
      MSG
    end
  end

  # Ai::Tools::BaseTool#effective_action_name falls back to the tool's own
  # definition name when no :action param is routed, and
  # Mcp::Principal.destructive_tool? returns FALSE for an empty name — it fails
  # OPEN. That fallback is only safe while no reachable tool has a blank name.
  describe "the overlay's empty-name fallback is unreachable" do
    it "gives every MCP-registered tool class a non-empty definition name" do
      blank = ::Ai::Tools::PlatformApiToolRegistry.all_tools.values.uniq.filter_map do |class_name|
        klass = class_name.safe_constantize
        next if klass.nil?

        klass.name if klass.definition[:name].to_s.strip.empty?
      end

      expect(blank).to be_empty
    end
  end

  # ── 2. The funnel: what a nested tool is told about its caller ───────────
  describe "BaseSkillExecutor#tool" do
    let(:executor_class) do
      Class.new(::System::Ai::Skills::BaseSkillExecutor) do
        def self.name = "System::Ai::Skills::SpecNestingExecutor"
        skill_descriptor(name: "spec_nesting", description: "spec", category: "fleet",
                         inputs: {}, outputs: {})
        def nested = tool(::Ai::Tools::SdwanTool)
      end
    end

    it "does NOT mark an instance-served executor's nested tool as an internal caller" do
      served = executor_class.new(account: account, user: nil)
      served.instance_authorized = true
      served.node_instance = node_instance
      nested = served.nested

      expect(nested.send(:internal?)).to be false
      expect(nested.send(:instance_authorized?)).to be true
    end

    it "still marks a reconciler's nested tool as an internal caller" do
      nested = executor_class.new(account: account, user: nil).nested

      expect(nested.send(:internal?)).to be true
      expect(nested.send(:instance_authorized?)).to be false
    end

    # Composition must keep working: the operator granted the composer, and its
    # benign internal steps are what the grant bought. Only the deny overlay
    # bounds them — losing that distinction would turn a privilege fix into an
    # outage for every instance granted a composer.
    it "leaves a benign nested action permitted for an instance-served executor" do
      served = executor_class.new(account: account, user: nil)
      served.instance_authorized = true

      expect(served.nested.send(:action_permitted?, "system_sdwan_create_virtual_ip")).to be true
    end
  end

  # ── 3. The escalation, end to end, against a destroy-shaped tool ─────────
  #
  # Every link here is production code: the real SystemIngressTool hop, the real
  # ArchitectureDeleteExecutor (a shipped CrudFactory subclass), the real
  # CrudFactory ROUTES entry, and the real SystemArchitectureCatalogTool running
  # "system_delete_architecture". Only the PAIRING is synthetic — stub_const
  # redirects one ACTION_EXECUTORS route, because no shipped composer nests a
  # destroy-shaped action today. That is the point: the fence must hold for the
  # composer someone writes next, not only for the ones in the tree now.
  describe "reaching a destroy-shaped tool by nesting" do
    let!(:architecture) { create(:system_node_architecture, is_canonical: false) }

    before do
      stub_const("Ai::Tools::SystemIngressTool::ACTION_EXECUTORS",
                 { "system_expose_service_publicly" => "System::Ai::Skills::ArchitectureDeleteExecutor" })
    end

    def invoke_as_instance
      tool = ::Ai::Tools::SystemIngressTool.new(account: account, user: nil)
      tool.instance_authorized = true
      tool.node_instance = node_instance
      tool.execute(params: { action: "system_expose_service_publicly", architecture_id: architecture.id })
    end

    it "refuses the nested destroy-shaped action and leaves the row intact" do
      # The name the nesting reaches is one the first hop would have refused.
      expect(principal.may_invoke?("platform.system_delete_architecture")).to be false

      result = invoke_as_instance

      expect(result[:success]).to be false
      expect(result[:error].to_s).to match(/destroy-shaped|denied/i)
      expect(::System::NodeArchitecture.exists?(architecture.id)).to be true
    end

    # Deny wins over any grant — at any depth. The overlay's whole promise is
    # that it cannot be granted away, so the widest possible grant must not buy
    # the nested destroy either.
    it "refuses it under a maximally permissive grant too" do
      ::Mcp::Principal.tool_grant_resolver = ->(_i) { [ "platform.*" ] }

      result = invoke_as_instance

      expect(result[:success]).to be false
      expect(::System::NodeArchitecture.exists?(architecture.id)).to be true
    end

    # The reconciler path this must not break: DecisionEngine builds executors
    # with user: nil and no instance provenance, and legitimately means
    # "trusted in-process caller".
    it "still lets a userless in-process caller run the same destroy-shaped action" do
      result = ::System::Ai::Skills::ArchitectureDeleteExecutor
                 .new(account: account, agent: nil, user: nil)
                 .execute(architecture_id: architecture.id)

      expect(result[:success]).to be true
      expect(::System::NodeArchitecture.exists?(architecture.id)).to be false
    end
  end

  # ── 4. Provenance must survive executor → executor nesting too ───────────
  describe "executor → executor nesting" do
    let(:child_class) do
      Class.new(::System::Ai::Skills::BaseSkillExecutor) do
        def self.name = "System::Ai::Skills::SpecChildExecutor"
        skill_descriptor(name: "spec_child", description: "spec", category: "fleet",
                         inputs: {}, outputs: {})
        def nested = tool(::Ai::Tools::SdwanTool)
      end
    end

    let(:parent_class) do
      Class.new(::System::Ai::Skills::BaseSkillExecutor) do
        def self.name = "System::Ai::Skills::SpecParentExecutor"
        skill_descriptor(name: "spec_parent", description: "spec", category: "fleet",
                         inputs: {}, outputs: {})
        def child(klass) = executor(klass)
      end
    end

    it "carries the instance provenance one more hop down" do
      parent = parent_class.new(account: account, user: nil)
      parent.instance_authorized = true
      parent.node_instance = node_instance
      child = parent.child(child_class)

      expect(child.nested.send(:internal?)).to be false
      expect(child.nested.send(:instance_authorized?)).to be true
    end

    it "leaves a reconciler's child executor internal" do
      child = parent_class.new(account: account, user: nil).child(child_class)

      expect(child.nested.send(:internal?)).to be true
    end
  end
end
