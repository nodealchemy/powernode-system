# frozen_string_literal: true

require "rails_helper"

# IMP-0467eee9fc57 — a cordon-only (unschedulable) mode for a NodeInstance.
#
# THE GAP THIS CLOSES. docs/runbooks/node-provisioning.md documented a
# `cordon_only` parameter on system_drain_instance that never existed; the doc
# was corrected (IMP-b4d9d7908c48) and the capability the false parameter stood
# in for is carried here: a REVERSIBLE "stop scheduling new work here, leave
# what is running alone" mode, distinct from the drain (cordon + STOP) and from
# the irreversible terminate — the Kubernetes cordon/uncordon shape at the
# platform layer.
#
# Two verbs, ONE operator control: both directions are gated under
# `system.instance_cordon` (operator direction: require_approval default). The
# uncordon is gated too, on purpose — an agent re-admitting a node an operator
# cordoned for maintenance is the ops-hold lesson ("a hold that lifts itself
# part-way through maintenance is worse than no hold").
#
# THE ORACLE IS THE ROW, in every example (IMP-ce5d320d3e4e): each gated example
# reads the instance back and checks the marker was NOT written and the pool
# member was NOT fenced; the approval-replay and auto_approve examples prove the
# verb still cordons, so "gated" cannot be satisfied by a verb that refuses
# everything.
RSpec.describe "SystemFleetTool instance cordon gating (IMP-0467eee9fc57)" do
  let(:category) { Ai::Tools::SystemFleetTool::INSTANCE_CORDON_CATEGORY }

  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template, name: "cordon-node") }
  # system.nodes.read is the tool floor Ai::Executors::DeferredToolCall
  # re-asks for before replaying an approved call.
  let(:user) do
    create(:user, account: account,
                  permissions: %w[system.nodes.read system.node_instances.read system.instances.control])
  end
  let(:tool) { Ai::Tools::SystemFleetTool.new(account: account, user: user) }

  let!(:pool) do
    ::System::InstancePool.create!(
      account: account, node_template: template, name: "cordon-pool",
      target_size: 1, min_size: 0, max_size: 2, lifecycle_class: "ephemeral"
    )
  end
  let!(:instance) do
    create(:system_node_instance, :running, node: node, account: account,
                                            instance_pool_id: pool.id, pool_state: "ready",
                                            pool_warming_started_at: 1.minute.ago)
  end

  def cordon!(id = instance.id, reason: "maintenance window")
    tool.execute(params: { action: "system_cordon_instance", instance_id: id, reason: reason }
                         .with_indifferent_access)
  end

  def uncordon!(id = instance.id)
    tool.execute(params: { action: "system_uncordon_instance", instance_id: id }.with_indifferent_access)
  end

  def latest_deferred
    ::Ai::DeferredOperation.where(account_id: account.id).order(created_at: :desc).first
  end

  def cordoned?
    ::System::InstanceCordonService.cordoned?(instance.reload)
  end

  describe "the declarations" do
    %w[system_cordon_instance system_uncordon_instance].each do |verb|
      it "arms #{verb} with the full quartet on the generic replay executor" do
        declaration = Ai::Tools::SystemFleetTool.declared_action(verb)

        expect(declaration).to be_present
        aggregate_failures do
          expect(declaration[:mutating]).to be(true)
          expect(declaration[:action_category]).to eq(category)
          expect(declaration[:executor_class]).to eq("Ai::Executors::DeferredToolCall")
          expect(declaration[:gate_context]).to be_present
          expect(declaration[:on_proceed]).to be_present
        end
      end

      it "requires the lifecycle grant system_stop_instance requires for #{verb}" do
        expect(Ai::Tools::SystemFleetTool::ACTION_PERMISSIONS.fetch(verb)).to eq("system.instances.control")
      end

      # An agent reads the CATALOG. A gated verb whose description reads as a
      # plain write is one an agent reports as completed on a pending envelope.
      it "announces the gate in the description an agent reads for #{verb}" do
        description = Ai::Tools::SystemFleetTool.action_definitions[verb][:description]

        expect(description).to include(category)
        expect(description).to match(/pending/i)
      end
    end

    # Pinned as a literal, not only through the constant: the category is the
    # operator's handle in the Autonomy modal and the seed's key.
    it "names the category the operator direction settled" do
      expect(category).to eq("system.instance_cordon")
    end

    it "declares the category at the operator (global) shape, require_approval, in the same change" do
      declared = ::System::Governance::PolicyDeclarations::INSTANCE_CORDON_OPERATOR_POLICIES
      expect(declared.fetch(category)).to eq("require_approval")

      set = ::System::Governance::PolicyDeclarations::POLICY_SETS.find { |s| s[:policies].key?(category) }
      expect(set).to be_present, "no POLICY_SETS entry carries #{category}"
      expect(set[:agent_key]).to be_nil
      expect(set[:scope]).to eq("global")
    end

    it "registers the category so the Autonomy modal can save a row for it" do
      expect(Ai::InterventionPolicy.category_registered?(category)).to be(true)
    end

    it "pivots into the node_lifecycle domain of the Autonomy modal" do
      prefixes = ::System::AutonomyActions::DOMAIN_PREFIXES.fetch("node_lifecycle")
      expect(prefixes.any? { |p| category.start_with?(p) }).to be(true),
                                                                "#{category} matches no node_lifecycle prefix: #{prefixes.inspect}"
    end

    it "is minted by the governance reconciler at the operator shape" do
      ::System::Governance::PolicyReconciler.new(account: account).reconcile!

      row = ::Ai::InterventionPolicy.find_by(account: account, action_category: category,
                                             scope: "global", ai_agent_id: nil)
      expect(row).to be_present
      expect(row.policy).to eq("require_approval")
    end
  end

  describe "cordoning over MCP with no operator row" do
    it "parks the cordon instead of fencing the member" do
      expect { cordon! }.to change(::Ai::DeferredOperation, :count).by(1)

      expect(cordoned?).to be(false)
      expect(instance.reload.pool_state).to eq("ready")
      expect(latest_deferred.action_category).to eq(category)
      expect(latest_deferred.executor_class).to eq("Ai::Executors::DeferredToolCall")
    end

    it "anchors the parked operation to the instance row" do
      cordon!

      expect(latest_deferred.source_type).to eq("System::NodeInstance")
      expect(latest_deferred.source_id).to eq(instance.id)
    end

    it "answers the caller with the pending envelope" do
      response = cordon!

      expect(response[:success]).to be(true)
      expect(response[:data][:pending]).to be(true)
      expect(response[:data][:action_category]).to eq(category)
      expect(response[:data][:deferred_operation_id]).to eq(latest_deferred.id)
    end

    it "really cordons when the parked operation is approved" do
      cordon!

      latest_deferred.execute_now!

      expect(cordoned?).to be(true)
      expect(instance.reload.pool_state).to eq("draining")
      expect(instance.status).to eq("running")
    end
  end

  describe "the auto_approve tier" do
    before do
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
    end

    it "cordons a ready pool member: marker written, allocator fenced, instance still running" do
      response = cordon!

      expect(response[:success]).to be(true)
      expect(response[:data][:cordoned]).to be(true)
      expect(response[:data][:cordon_state]).to eq("fenced")
      expect(response[:data][:status]).to eq("running")
      expect(cordoned?).to be(true)
      expect(instance.reload.pool_state).to eq("draining")
    end

    it "makes the member un-acquirable through the real allocator" do
      cordon!

      expect {
        ::System::InstancePoolService.acquire!(account: account, pool_id: pool.id)
      }.to raise_error(::System::InstancePoolService::NoReadyMembersError)
    end

    it "uncordons: marker cleared and the member handed back to the allocator" do
      cordon!

      response = uncordon!

      expect(response[:success]).to be(true)
      expect(response[:data][:cordoned]).to be(false)
      expect(response[:data][:pool_state]).to eq("ready")
      expect(cordoned?).to be(false)
      expect(instance.reload.pool_state).to eq("ready")
      expect(::System::InstancePoolService.acquire!(account: account, pool_id: pool.id).id).to eq(instance.id)
    end

    it "refuses to uncordon an instance that is not cordoned, without a write" do
      response = uncordon!

      expect(response[:success]).to be(false)
      expect(response[:error]).to match(/not cordoned/)
      expect(instance.reload.pool_state).to eq("ready")
    end

    it "refuses a second cordon on an already-cordoned instance" do
      cordon!

      response = cordon!

      expect(response[:success]).to be(false)
      expect(response[:error]).to match(/already cordoned/)
    end

    it "never stops the instance — this is the cordon-ONLY mode" do
      expect(::System::InstanceControlService).not_to receive(:execute)

      cordon!

      expect(instance.reload.status).to eq("running")
    end
  end

  describe "a policy row for the declared category actually binds both verbs" do
    before do
      ::Ai::InterventionPolicy.create!(
        account: account, action_category: category,
        scope: "global", ai_agent_id: nil, user_id: nil,
        policy: "block", priority: 5, is_active: true,
        conditions: {}, preferred_channels: %w[notification]
      )
    end

    it "blocks the cordon and writes nothing" do
      response = cordon!

      expect(response[:success]).to be(false)
      expect(response[:error]).to be_present
      expect(cordoned?).to be(false)
      expect(instance.reload.pool_state).to eq("ready")
    end

    it "blocks the uncordon and leaves the cordon in place" do
      ::System::InstanceCordonService.cordon!(instance: instance, user: user, reason: "pre-set")

      response = uncordon!

      expect(response[:success]).to be(false)
      expect(cordoned?).to be(true)
      expect(instance.reload.pool_state).to eq("draining")
    end
  end

  describe "authorization is not lost to the gate" do
    let(:user) { create(:user, account: account, permissions: %w[system.nodes.read]) }

    it "refuses an unauthorized caller and parks nothing" do
      response = cordon!

      expect(response[:success]).to be(false)
      expect(response[:error]).to include("permission denied")
      expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
    end
  end

  describe "a target that cannot be resolved parks nothing" do
    it "refuses an unknown instance with the inline error, minting no approval" do
      response = cordon!(SecureRandom.uuid)

      expect(response[:success]).to be(false)
      expect(response[:error]).to eq("Instance not found")
      expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
    end

    # The IMP-785d60f5ec3e shape: a call that could only ever be refused on
    # replay keeps its inline error rather than parking an approval an
    # operator then has to dispose of. With NO operator row the gate would
    # otherwise park every one of these.
    it "refuses to park a second cordon on an already-cordoned instance" do
      ::System::InstanceCordonService.cordon!(instance: instance, user: user, reason: "pre-set")

      response = cordon!

      expect(response[:success]).to be(false)
      expect(response[:error]).to match(/already cordoned/)
      expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
    end

    it "refuses to park a cordon with a blank reason" do
      response = cordon!(reason: " ")

      expect(response[:success]).to be(false)
      expect(response[:error]).to match(/reason is required/)
      expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      expect(instance.reload.pool_state).to eq("ready")
    end

    it "refuses to park an uncordon of an instance that is not cordoned" do
      response = uncordon!

      expect(response[:success]).to be(false)
      expect(response[:error]).to match(/not cordoned/)
      expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
    end

    it "refuses another account's instance the same way" do
      other = create(:account)
      foreign_node = create(:system_node, account: other, node_template: create(:system_node_template, account: other))
      foreign = create(:system_node_instance, :running, node: foreign_node, account: other)

      response = cordon!(foreign.id)

      expect(response[:success]).to be(false)
      expect(response[:error]).to eq("Instance not found")
      expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      expect(::System::InstanceCordonService.cordoned?(foreign.reload)).to be(false)
    end
  end
end
