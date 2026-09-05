# frozen_string_literal: true

require "rails_helper"

# IMP-c2e3e5d3cff0 (a) — the SERVICE-SEAM hop.
#
# IMP-0e6b216de843 routed every executor a TOOL builds through
# Ai::Tools::BaseTool#build_skill_executor, and guarded it by scanning tool
# files for executor construction. A tool that calls a plain SERVICE, which
# then builds the executor, is the same bypass one layer out — and structurally
# invisible to that guard, because the construction is not in a tool file.
#
# Ai::Tools::SystemFleetTool#deploy_inference_server (MCP action
# system_deploy_inference_server) calls System::InferenceDeploymentService
# .deploy!, whose #compose_offering built a bare
# ServiceDiscoveryComposerExecutor.new(account:). With no user and no
# provenance, BaseSkillExecutor#internal_caller? is true, so every tool that
# executor nests would be built `internal: true` — the reconciler bypass handed
# to a grant-gated MCP instance principal.
#
# TWO defects at this one site, and the second is live:
#
#   1. provenance is dropped (latent — the composer nests no BaseTool today,
#      asserted below so it stops being an assumption).
#   2. #perform is PROTECTED on BaseSkillExecutor subclasses, so calling it
#      from a service raises NoMethodError, which #compose_offering's bare
#      `rescue StandardError` swallows into a warn. Every deploy silently
#      skipped SDWAN service-discovery publication. Calling #execute instead
#      is what the class actually exposes, and it restores the input
#      validation and the audit-log bracket that #perform skips.
RSpec.describe "service-seam instance provenance", type: :service do
  let(:account) { create(:account) }
  let(:node_instance_principal) { double("NodeInstance", id: SecureRandom.uuid, account: account) }

  # ── Defect 2: the seam never reached the executor at all ─────────────────
  describe "System::Ai::Skills::ServiceDiscoveryComposerExecutor's callable surface" do
    it "does not expose #perform to an outside caller" do
      executor = ::System::Ai::Skills::ServiceDiscoveryComposerExecutor.new(account: account)

      expect(executor.respond_to?(:perform)).to be false
      expect(described_class_for_perform_visibility).to eq(:protected)
    end

    it "exposes #execute, which brackets the run with validation and audit" do
      expect(::System::Ai::Skills::ServiceDiscoveryComposerExecutor
               .public_method_defined?(:execute)).to be true
    end

    def described_class_for_perform_visibility
      k = ::System::Ai::Skills::ServiceDiscoveryComposerExecutor
      return :protected if k.protected_method_defined?(:perform)
      return :public if k.public_method_defined?(:perform)

      :private
    end
  end

  describe "System::InferenceDeploymentService#compose_offering" do
    let(:instance) { create(:system_node_instance, account: account) }

    # A spy standing in for the composer, so these assert on the SEAM rather
    # than on SDWAN composition. It exposes the provenance writers the real
    # BaseSkillExecutor has (attr_accessor :node_instance, attr_writer
    # :instance_authorized) and, deliberately, a PUBLIC #execute only — a spy
    # with a public #perform would hide defect 2.
    let(:composer_spy) do
      Class.new do
        attr_accessor :node_instance
        attr_writer :instance_authorized
        attr_reader :calls

        def initialize(**) = @calls = []

        def instance_authorized = @instance_authorized == true

        def execute(**kwargs)
          @calls << kwargs
          { success: true, data: { offering_id: "off-1", vip_address: "10.9.9.9" } }
        end
      end
    end

    # Drive #compose_offering directly. The rest of #deploy! (module catalog
    # lookup, provider upsert) is not under test, and stubbing it out would say
    # less about the seam than calling the seam does.
    def compose(instance_authorized: false, node_instance: nil)
      # Production reads it as `instance.try(:sdwan_peer_id)` — NodeInstance has
      # no such column, so stub the call that is actually made.
      allow(instance).to receive(:try).and_call_original
      allow(instance).to receive(:try).with(:sdwan_peer_id).and_return(SecureRandom.uuid)

      service = ::System::InferenceDeploymentService.new(
        account: account, instance_authorized: instance_authorized, node_instance: node_instance
      )
      service.send(:compose_offering, instance: instance,
                                      sdwan_network_id: SecureRandom.uuid,
                                      vip_cidr: "10.9.9.0/24", port: 11434)
    end

    it "reaches the composer at all (it did not — #perform is protected)" do
      spy = composer_spy.new
      allow(::System::Ai::Skills::ServiceDiscoveryComposerExecutor).to receive(:new).and_return(spy)

      result = compose

      expect(spy.calls.size).to eq(1)
      expect(spy.calls.first[:service_slug]).to be_present
      # ...and the composed offering actually reaches the caller, rather than
      # being swallowed to nil by the bare rescue.
      expect(result).to eq(offering_id: "off-1", vip_address: "10.9.9.9")
    end

    # APO-1c (IMP-7e2bdc1774e4). ServiceDiscoveryComposerExecutor declares
    # `requires_approval: true`, and BaseSkillExecutor#execute now resolves
    # Ai::InterventionPolicy before #perform. #compose_offering ends in
    # `return nil unless result[:success]`, so an ungated call on an install
    # with no policy row would turn a parked approval into a SILENT SKIP of the
    # SDWAN publication — bit-for-bit the symptom IMP-c2e3e5d3cff0 fixed here.
    # The seam is the publication half of an already-authorised deploy, not a
    # door of its own, so it asserts `gated: true` the way the tick loop does.
    #
    # The spy cannot observe the gate (it is not a BaseSkillExecutor), so what
    # is pinned here is the KEYWORD; what `gated: true` then does to the real
    # gate is pinned in
    # spec/services/system/ai/skills/base_skill_executor_gating_spec.rb.
    it "stands the composer's approval gate down — the deploy already carried the decision" do
      spy = composer_spy.new
      allow(::System::Ai::Skills::ServiceDiscoveryComposerExecutor).to receive(:new).and_return(spy)

      compose

      expect(spy.calls.first[:gated]).to be true
    end

    it "hands the composer the instance provenance when the caller is an instance" do
      spy = composer_spy.new
      allow(::System::Ai::Skills::ServiceDiscoveryComposerExecutor).to receive(:new).and_return(spy)

      compose(instance_authorized: true, node_instance: node_instance_principal)

      expect(spy.instance_authorized).to be true
      expect(spy.node_instance).to eq(node_instance_principal)
    end

    # The reconciler / operator path: no provenance passed, nothing marked.
    it "leaves the composer unmarked for a caller with no instance provenance" do
      spy = composer_spy.new
      allow(::System::Ai::Skills::ServiceDiscoveryComposerExecutor).to receive(:new).and_return(spy)

      compose

      expect(spy.instance_authorized).to be false
      expect(spy.node_instance).to be_nil
    end

    # .deploy! is the entry point every caller uses; the plumbing is inert if
    # it does not forward what it was given.
    it "threads provenance from .deploy! into the service instance" do
      captured = nil
      allow(::System::InferenceDeploymentService).to receive(:new) do |**kwargs|
        captured = kwargs
        instance_double(::System::InferenceDeploymentService, deploy!: :ok)
      end

      ::System::InferenceDeploymentService.deploy!(
        account: account, instance: instance,
        instance_authorized: true, node_instance: node_instance_principal
      )

      expect(captured).to include(account: account, instance_authorized: true,
                                  node_instance: node_instance_principal)
    end
  end

  # The tool end of the seam: SystemFleetTool must actually forward what it
  # knows, or the service-side plumbing is inert.
  describe "Ai::Tools::SystemFleetTool#deploy_inference_server" do
    let!(:instance) { create(:system_node_instance, account: account) }

    def capture_deploy_kwargs(tool)
      captured = nil
      allow(::System::InferenceDeploymentService).to receive(:deploy!) do |**kwargs|
        captured = kwargs
        { deployed: true }
      end
      allow(tool).to receive(:resolve_inference_target).and_return(instance)
      tool.execute(params: { action: "system_deploy_inference_server",
                             instance_id: instance.id }.with_indifferent_access)
      captured
    end

    it "forwards the instance provenance to the service" do
      tool = ::Ai::Tools::SystemFleetTool.new(account: account, user: nil)
      tool.instance_authorized = true
      tool.node_instance = node_instance_principal

      kwargs = capture_deploy_kwargs(tool)

      expect(kwargs[:instance_authorized]).to be true
      expect(kwargs[:node_instance]).to eq(node_instance_principal)
    end

    it "forwards no provenance for a user principal" do
      operator = create(:user, account: account, permissions: %w[system.instances.create])
      kwargs = capture_deploy_kwargs(::Ai::Tools::SystemFleetTool.new(account: account, user: operator))

      expect(kwargs[:instance_authorized]).to be false
      expect(kwargs[:node_instance]).to be_nil
    end
  end

  # ── Assumption made explicit ─────────────────────────────────────────────
  #
  # The provenance drop was only ever LATENT because this composer nests no
  # BaseTool. That is a property of today's code, not a guarantee — assert it
  # so the day it changes, this fails instead of silently becoming exploitable.
  describe "why the drop was latent" do
    it "ServiceDiscoveryComposerExecutor nests no tool and no child executor" do
      src = File.read(Rails.root.join(
        "../extensions/system/server/app/services/system/ai/skills/service_discovery_composer_executor.rb"
      ))
      body = src.lines.reject { |l| l.strip.start_with?("#") }.join

      expect(body).not_to match(/\btool\(/)
      expect(body).not_to match(/\bexecutor\(/)
    end
  end

  # ── The guard arm the funnel scan is missing ─────────────────────────────
  #
  # nested_executor_instance_principal_spec.rb scans TOOL files for executor
  # construction. Services build executors too, and three sites did so with no
  # caller context at all. A pure inventory guard is the honest control here:
  # statically proving "this one carries provenance" is fragile, but requiring
  # every service-seam site to be DECLARED with a reason means a new one cannot
  # appear without a reviewer reading the justification.
  describe "every service-seam executor construction is declared" do
    # "<basename>:<ExecutorClass>" => why this seam is safe.
    DECLARED_SERVICE_SEAM_CONSTRUCTION = {
      "inference_deployment_service.rb:ServiceDiscoveryComposerExecutor" =>
        "Carries provenance: #deploy! threads instance_authorized:/node_instance: " \
        "from Ai::Tools::SystemFleetTool into #compose_offering. (IMP-c2e3e5d3cff0)",

      "cve_responder_service.rb:CveRemediationOrchestrationExecutor" =>
        "Reconciler-only. Reached from the worker-API tick and " \
        "System::Fleet::DecisionEngine, never from an MCP tool, and passes " \
        "user: nil meaning a genuine in-process caller. No principal exists to " \
        "carry.",

      "grant_review_service.rb:FederationManagerExecutor" =>
        "Reconciler-shaped and currently unreferenced in production code (spec " \
        "only). Nests no tool. If it gains a caller, that caller must thread " \
        "provenance and this entry must be revisited.",

      "fulfillment_advance_orchestrator.rb:ProvisionFullStackExecutor" =>
        "Passes user: effective_user, so internal_caller? is already false and " \
        "no reconciler bypass is handed out. Reached from the REST " \
        "fulfillment controllers, not the MCP tool surface. (The " \
        "effective_user fallback to an arbitrary account user is tracked " \
        "separately as the IMP-496d1870009b anti-pattern — not a provenance " \
        "defect.)",

      "fulfillment_advance_orchestrator.rb:ModuleSmokeVerifyExecutor" =>
        "Same seam and same reasoning as ProvisionFullStackExecutor above.",

      "scheduled_health_check_service.rb:PlatformMaintenanceExecutor" =>
        "Scheduler-only. Reached from the worker-API tick " \
        "(Api::V1::System::WorkerApi::PlatformHealthController#run_due), " \
        "never from an MCP tool, and passes user: nil meaning a genuine " \
        "in-process caller. Runs `gated: true` with the fixed action " \
        "health_check, a read-only probe that nests no tool, so there is no " \
        "bypass to hand out and no principal to carry."
    }.freeze

    let(:service_sources) do
      (Dir[Rails.root.join("../extensions/system/server/app/services/**/*.rb")] +
        Dir[Rails.root.join("app/services/**/*.rb")])
        .reject { |path| path.include?("/ai/tools/") }
        .reject { |path| path.end_with?("base_skill_executor.rb") }
    end

    it "finds no undeclared executor construction outside the tool tree" do
      expect(service_sources).not_to be_empty

      # Multi-line aware: the sites in fulfillment_advance_orchestrator.rb put
      # `.new(` on the line after the class, and a single-line regex misses
      # exactly the shape this guard exists to catch.
      pattern = /(?:::)?System::Ai::Skills::(\w+Executor)\s*(?:\n\s*)?\.new\(/m

      undeclared = service_sources.flat_map do |path|
        src = File.read(path)
        src.to_enum(:scan, pattern).map { Regexp.last_match }.filter_map do |m|
          key = "#{File.basename(path)}:#{m[1]}"
          next if DECLARED_SERVICE_SEAM_CONSTRUCTION.key?(key)

          "#{key} (#{path.sub(%r{\A.*/(server|extensions)/}, '\1/')}:" \
            "#{src[0...m.begin(0)].count("\n") + 1})"
        end
      end

      expect(undeclared).to be_empty, <<~MSG
        These build a skill executor from a plain SERVICE, where the
        IMP-0e6b216de843 funnel guard cannot see them. A service that a tool
        can reach must thread the caller's instance provenance, or the
        executor reads its nil user as "trusted in-process caller" and hands
        every tool it nests the internal bypass.

        Thread instance_authorized:/node_instance: from the calling tool, or
        add a DECLARED_SERVICE_SEAM_CONSTRUCTION entry stating why this seam
        cannot be reached by an MCP instance principal:

        #{undeclared.join("\n")}
      MSG
    end
  end
end
