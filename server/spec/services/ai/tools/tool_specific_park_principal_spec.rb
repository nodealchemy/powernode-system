# frozen_string_literal: true

require "rails_helper"

# IMP-a33f7a833313 — every park this extension's tools make through a
# TOOL-SPECIFIC gate records the same principal block the generic
# DeferredToolCall park does, minted by ONE builder (Ai::Approvals::ParkPrincipal)
# from the tool's own state. Before this, SdwanTool#gated_result, the bespoke
# SystemFleetTool gate contexts and the skill executors' own gate parked rows
# that named no principal, so an instance principal could not read back a
# request it had itself parked (AgentAutonomyTool#get_approval_request fails
# closed on a row that records no principal), and a person's or agent's park
# through those doors carried no attribution beyond requested_by/ai_agent.
RSpec.describe "extension tool-specific gate parks record the originating principal" do
  let(:account) { create(:account) }
  let(:own_instance)   { Struct.new(:id).new(SecureRandom.uuid) }
  let(:other_instance) { Struct.new(:id).new(SecureRandom.uuid) }
  let(:not_found) { { success: false, error: "Approval request not found" } }

  after { ::Mcp::Principal.reset! }

  def run_as_instance(tool_id, params, node_instance:)
    ::Ai::Tools::McpPlatformToolRegistrar.execute_tool(
      tool_id, params: params, account: account, user: nil,
               instance_authorized: true, node_instance: node_instance, origin: "mcp_instance"
    )
  end

  def read_as_instance(operation, node_instance:)
    run_as_instance("platform.get_approval_request", { "deferred_operation_id" => operation.id },
                    node_instance: node_instance)
  end

  # SdwanTool#gated_result: a hand-placed Ai::AutonomyGate.evaluate with
  # executor params the tool assembles itself.
  describe "SdwanTool#gated_result" do
    before do
      ::Sdwan::Configuration.where(account_id: account.id).delete_all
      ::Sdwan::Network.where(account_id: account.id).delete_all
    end

    it "lets the parking instance read its request and refuses another instance" do
      # A fresh account has no policy row; InterventionPolicyService falls
      # through to its require_approval default, so this parks.
      parked = run_as_instance("platform.system_sdwan_create_network",
                               { "name" => "edge-overlay", "description" => "perimeter" },
                               node_instance: own_instance)
      expect(parked[:success]).to be(true), parked.inspect
      expect(parked.dig(:data, :pending)).to be(true), parked.inspect
      operation = ::Ai::DeferredOperation.find(parked.dig(:data, :deferred_operation_id))

      own = read_as_instance(operation, node_instance: own_instance)
      expect(own).to include(success: true, deferred_operation_id: operation.id, action_category: "sdwan.network_create")
      expect(read_as_instance(operation, node_instance: other_instance)).to eq(not_found)

      expect(operation.executor_class).to eq("Sdwan::Executors::CreateNetwork")
      expect(operation.params.dig("attributes", "name")).to eq("edge-overlay")
      expect(operation.params["principal"]).to include(
        "kind" => "instance", "node_instance_id" => own_instance.id,
        "granted_tool_name" => "system_sdwan_create_network", "origin" => "mcp_instance"
      )
    end
  end

  # SystemFleetTool's bespoke gate contexts (terminate, out-of-band exec, DR
  # replace/reap) build executor params of their own rather than wrapping the
  # generic builder. An instance principal is refused at those doors (the
  # destroy-shaped deny overlay and their own guards), so the stamp there buys
  # a person's or agent's park the same discoverable descriptor.
  describe "a bespoke SystemFleetTool gate context" do
    let(:operator) do
      create(:user, account: account, permissions: %w[system.nodes.read system.instances.control ai.agents.read])
    end
    let(:instance) { create(:system_node_instance, account: account) }

    it "records the user principal the generic park records" do
      parked = ::Ai::Tools::McpPlatformToolRegistrar.execute_tool(
        "platform.system_terminate_instance", params: { "instance_id" => instance.id },
                                              account: account, user: operator, origin: "mcp_oauth"
      )
      expect(parked[:success]).to be(true), parked.inspect
      expect(parked.dig(:data, :pending)).to be(true), parked.inspect
      operation = ::Ai::DeferredOperation.find(parked.dig(:data, :deferred_operation_id))

      expect(operation.executor_class).to eq("System::Executors::TerminateInstance")
      expect(operation.params).to include("instance_id" => instance.id)
      expect(operation.params["principal"]).to eq(
        "kind" => "user", "user_id" => operator.id, "agent_id" => nil, "internal" => false, "origin" => "mcp_oauth"
      )
      # A person's park is nobody's instance park.
      expect(read_as_instance(operation, node_instance: own_instance)).to eq(not_found)
    end
  end

  # The skill executors' OWN gate (BaseSkillExecutor#gate_action!) is a park
  # path too, and BaseTool#build_skill_executor hands it the instance
  # provenance, so an instance can park there (SystemIngressTool#run_executor
  # onto the expose_service_* executors, SdwanTool#run_skill_executor).
  describe "BaseSkillExecutor#gate_action!" do
    let(:parker) { create(:user, account: account) }

    let(:fixture_class) do
      Class.new(::System::Ai::Skills::BaseSkillExecutor) do
        def self.performed_with
          @performed_with ||= []
        end

        skill_descriptor(
          name: "zz_park_principal_fixture",
          description: "park principal fixture",
          category: "fleet",
          requires_approval: true,
          inputs: { widget_id: { type: "string", required: true } },
          outputs: { widget_id: :string }
        )

        protected

        # A keyrest signature, the shape that would receive every stored key
        # on replay (PlatformDeployExecutor, PlatformMaintenanceExecutor...).
        def perform(widget_id:, **rest)
          self.class.performed_with << rest
          success(widget_id: widget_id)
        end
      end
    end

    before do
      stub_const("ZzParkPrincipalFixtureExecutor", fixture_class)
      ::Ai::InterventionPolicy.register_category!("system.zz_park_principal_fixture")
      ::Ai::InterventionPolicy.create!(
        account: account, action_category: "system.zz_park_principal_fixture",
        scope: "global", policy: "require_approval", priority: 5, is_active: true
      )
    end

    def instance_executor(node_instance)
      executor = ZzParkPrincipalFixtureExecutor.new(account: account, user: nil)
      executor.instance_authorized = true
      executor.node_instance = node_instance
      executor
    end

    it "records the instance that parked, readable by it and by no other instance" do
      result = instance_executor(own_instance).execute(widget_id: "w-1")
      expect(result[:success]).to be(true), result.inspect
      operation = ::Ai::DeferredOperation.where(account: account).last

      expect(read_as_instance(operation, node_instance: own_instance)[:success]).to be(true)
      expect(read_as_instance(operation, node_instance: other_instance)).to eq(not_found)

      expect(operation.params).to include("widget_id" => "w-1")
      expect(operation.params["principal"]).to include("kind" => "instance", "node_instance_id" => own_instance.id)
    end

    it "records a user principal and keeps the record out of #perform on replay" do
      ZzParkPrincipalFixtureExecutor.new(account: account, user: parker).execute(widget_id: "w-2")
      operation = ::Ai::DeferredOperation.where(account: account).last

      expect(operation.params["principal"]).to include("kind" => "user", "user_id" => parker.id, "internal" => false)

      operation.update_columns(status: "approved")
      replay = ZzParkPrincipalFixtureExecutor.execute(operation.params, deferred_operation: operation)

      expect(replay[:success]).to be(true), replay.inspect
      expect(ZzParkPrincipalFixtureExecutor.performed_with).to eq([ {} ])
      expect(::Ai::DeferredOperation.where(account: account).count).to eq(1)
    end
  end
end
