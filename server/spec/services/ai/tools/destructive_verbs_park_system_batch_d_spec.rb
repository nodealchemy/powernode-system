# frozen_string_literal: true

require "rails_helper"

# c13-2 batch E-D, the final extension batch: the four verbs the operator held
# through batches E-A..E-C (upgrade_boot_image, drain_instance, recycle_pool,
# delete_architecture) are now require_approval (none human_only). Each parks
# through Ai::Executors::DeferredToolCall and replays as the original caller,
# with the tool's own per-action permission check running BEFORE the park and
# again at replay. Every example asserts the row or the service call as well as
# the envelope.
RSpec.describe "c13-2 batch E-D destructive system verbs park", type: :service do
  let(:account) { create(:account) }
  let!(:owner) { create(:user, account: account) } # first user: account owner

  let(:approver) { create(:user, account: account, permissions: %w[ai.autonomy.approve ai.agents.read]) }
  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform_record) }
  let(:node) { create(:system_node, account: account, node_template: template) }

  FLEET_D = Ai::Tools::SystemFleetTool
  ARCH_D = Ai::Tools::SystemArchitectureCatalogTool

  # Service calls the verbs would make, recorded by stubs so an example can see
  # whether anything ran.
  let(:acted) { [] }

  before do
    seen = acted
    allow(::System::InstanceControlService).to receive(:execute) do |**kw|
      seen << [ :stop, kw[:instance]&.id, kw[:action] ]
      ::System::Runtime::Result.ok(data: {})
    end
    allow(::System::InstancePoolService).to receive(:recycle_stale_members!) do |**kw|
      seen << [ :recycle, kw[:pool]&.id, kw[:actor] ]
      {}
    end
    allow(::System::BootImage::UpgradeDispatcher).to receive(:dispatch!) do |**kw|
      seen << [ :upgrade, kw[:instance]&.id ]
      double(ok?: true, already_current: false, deduplicated: false,
             task: double(id: SecureRandom.uuid, status: "pending"), target_git_sha: "abc123")
    end
  end

  # Restore, never reset!: reset! nils the resolvers the extension engine wires at
  # boot, which silently turns every later instance-principal example in the
  # process into a refusal.
  around do |example|
    orig_instance = ::Mcp::Principal.instance_resolver
    orig_grant = ::Mcp::Principal.tool_grant_resolver
    example.run
  ensure
    ::Mcp::Principal.instance_resolver = orig_instance
    ::Mcp::Principal.tool_grant_resolver = orig_grant
  end

  def user_with(*perms) = create(:user, account: account, permissions: perms)

  def run(klass, params, user:, agent: nil)
    tool = klass.new(account: account, user: user, agent: agent)
    tool.call_origin = "mcp_oauth"
    tool.execute(params: params.with_indifferent_access)
  end

  def expect_parked(result, category)
    expect(result).to include(success: true)
    expect(result[:data]).to include(pending: true)
    operation = Ai::DeferredOperation.find(result[:data][:deferred_operation_id])
    expect(operation.action_category).to eq(category)
    expect(operation.executor_class).to eq("Ai::Executors::DeferredToolCall")
    expect(Ai::ApprovalRequest.find(result[:data][:approval_request_id]).requires_human_session?).to be(true) # destructive: true
    operation
  end

  def approve!(parked)
    request = Ai::ApprovalRequest.find(parked[:data][:approval_request_id])
    decided = Ai::Autonomy::ApprovalWorkflowService.new(account: account)
                                                   .approve(request: request, approver: approver,
                                                            origin: Ai::ApprovalDecision::REST_SESSION)
    expect(decided).to be(true)
    Ai::DeferredOperation.find(parked[:data][:deferred_operation_id]).reload
  end

  def revoke!(user, permission)
    RolePermission.where(role_id: user.roles.select(:id), permission_name: permission).delete_all
  end

  def never(kind) = acted.none? { |a| a.first == kind } ? ::Account.where(id: account.id) : ::Account.none

  def pool_in(acct)
    region = create(:system_provider_region, account: acct)
    itype = create(:system_provider_instance_type, account: acct)
    tmpl = create(:system_node_template, account: acct, node_platform: create(:system_node_platform, account: acct))
    ::System::InstancePool.create!(account: acct, node_template: tmpl, name: "p-#{SecureRandom.hex(3)}",
                                   target_size: 0, min_size: 0, max_size: 5, lifecycle_class: "ephemeral",
                                   status: "archived", provider_region: region, provider_instance_type: itype)
  end

  CASES_D = [
    { action: "system_upgrade_boot_image", tool: FLEET_D, permission: "system.node_instances.manage",
      category: "system.task.upgrade_boot_image" },
    { action: "system_drain_instance", tool: FLEET_D, permission: "system.instances.control",
      category: "system.instance_drain" },
    { action: "system_recycle_pool", tool: FLEET_D, permission: "system.instances.control",
      category: "system.instance_pool_recycle" },
    { action: "system_delete_architecture", tool: ARCH_D, permission: "system.architectures.manage",
      category: "system.architecture.delete" }
  ].freeze

  # [params naming the target, -> relation that EXISTS while the verb has not acted]
  def target_for(action)
    case action
    when "system_upgrade_boot_image"
      i = create(:system_node_instance, :running, node: node)
      [ { instance_id: i.id }, -> { never(:upgrade) } ]
    when "system_drain_instance"
      i = create(:system_node_instance, :running, node: node)
      [ { instance_id: i.id }, -> { never(:stop) } ]
    when "system_recycle_pool"
      [ { pool_id: pool_in(account).id }, -> { never(:recycle) } ]
    when "system_delete_architecture"
      arch = create(:system_node_architecture)
      [ { architecture_id: arch.id }, -> { ::System::NodeArchitecture.where(id: arch.id) } ]
    end
  end

  CASES_D.each do |c|
    describe c[:action] do
      let(:tool_class) { c[:tool] }
      let(:caller_user) { user_with(c[:permission], c[:tool]::REQUIRED_PERMISSION) }
      let(:target) { target_for(c[:action]) }
      let(:params) { { action: c[:action] }.merge(target.first) }
      let(:intact) { target.last }

      def go(user:, agent: nil) = run(tool_class, params, user: user, agent: agent)

      it "declares the category and executor, require_approval, not human_only" do
        decl = tool_class.declared_action(c[:action])
        expect(decl).to include(action_category: c[:category], executor_class: "Ai::Executors::DeferredToolCall",
                                gate_context: :deferred_tool_call_context, on_proceed: :deferred_tool_call_result)
        expect(decl[:human_only]).to be_falsey
      end

      it "is never seeded at auto_approve or notify_and_proceed (unseeded defaults to require_approval)" do
        d = ::System::Governance::PolicyDeclarations
        # Every declared set, as autonomy_categories_registration_spec reads them.
        sets = [ d::MANUAL_OPERATION_POLICIES, d::OUT_OF_BAND_EXEC_POLICIES, d::UNIT_DROPIN_POLICIES,
                 d::SSH_HOST_KEY_CLEAR_POLICIES, d::BOOTSTRAP_TOKEN_POLICIES ] + d::POLICY_SETS.map { |set| set[:policies] }
        seeded = sets.filter_map { |set| set[c[:category]] }.uniq

        expect(seeded - [ "require_approval" ]).to be_empty
      end

      it "parks, leaving the target untouched and acting on nothing" do
        parked = go(user: caller_user)

        expect_parked(parked, c[:category])
        expect(intact.call).to exist
        expect(acted).to be_empty
      end

      it "acts on approval, as the original caller" do
        parked = go(user: caller_user)
        expect(intact.call).to exist

        operation = approve!(parked)

        expect(operation.status).to eq("completed")
        expect(operation.result.with_indifferent_access).not_to include(success: false)
        expect(intact.call).not_to exist
      end

      it "refuses the replay, acting on nothing, when the permission was revoked after parking" do
        parked = go(user: caller_user)
        revoke!(caller_user, c[:permission])

        operation = approve!(parked)

        expect(intact.call).to exist
        expect(acted).to be_empty
        expect(operation.result.with_indifferent_access).to include(success: false)
        expect(operation.result.with_indifferent_access[:error]).to match(/permission/i)
      end

      it "refuses a caller without the permission, and parks nothing" do
        denied = go(user: user_with(c[:tool]::REQUIRED_PERMISSION))

        expect(denied[:success]).to be(false)
        expect(denied[:error]).to match(/permission denied: #{Regexp.escape(c[:permission])}/)
        expect(Ai::DeferredOperation.count).to eq(0)
        expect(intact.call).to exist
      end

      it "refuses an agent principal with no user, and parks nothing" do
        denied = go(user: nil, agent: create(:ai_agent, account: account))

        expect(denied[:success]).to be(false)
        expect(Ai::DeferredOperation.count).to eq(0)
        expect(intact.call).to exist
      end
    end
  end

  describe "the parked request carries ids only" do
    it "packs the instance id, not the record, for the boot image upgrade" do
      instance = create(:system_node_instance, :running, node: node)
      parked = run(FLEET_D, { action: "system_upgrade_boot_image", instance_id: instance.id, force: true },
                   user: user_with("system.node_instances.manage", FLEET_D::REQUIRED_PERMISSION))
      operation = expect_parked(parked, "system.task.upgrade_boot_image")

      packed = operation.params.to_json
      expect(packed).to include(instance.id)
      expect(packed).not_to include(instance.name)
    end
  end

  describe "replay semantics" do
    it "recycles as the operator (the original caller was a user), not as the reaper" do
      pool = pool_in(account)
      parked = run(FLEET_D, { action: "system_recycle_pool", pool_id: pool.id },
                   user: user_with("system.instances.control", FLEET_D::REQUIRED_PERMISSION))

      approve!(parked)

      expect(acted).to eq([ [ :recycle, pool.id, :operator ] ])
    end

    it "still refuses a canonical architecture when the approved call replays" do
      canonical = create(:system_node_architecture, :canonical)
      parked = run(ARCH_D, { action: "system_delete_architecture", architecture_id: canonical.id },
                   user: user_with("system.architectures.manage", ARCH_D::REQUIRED_PERMISSION))

      expect(parked.dig(:data, :pending)).to be(true)
      replayed = approve!(parked).result.with_indifferent_access

      expect(replayed).to include(success: false)
      expect(replayed[:error]).to match(/canonical/i)
      expect(::System::NodeArchitecture.where(id: canonical.id)).to exist
    end
  end

  describe "account scoping at replay (the park does not validate scope, the replay must not reach the row)" do
    let(:other) { create(:account) }
    let(:other_node) do
      create(:system_node, account: other,
             node_template: create(:system_node_template, account: other,
                                   node_platform: create(:system_node_platform, account: other)))
    end

    it "does not upgrade another account's instance even when its id is parked" do
      foreign = create(:system_node_instance, :running, node: other_node)
      result = run(FLEET_D, { action: "system_upgrade_boot_image", instance_id: foreign.id },
                   user: user_with("system.node_instances.manage", FLEET_D::REQUIRED_PERMISSION))

      expect(result.dig(:data, :pending)).to be(true)
      replayed = approve!(result).result.with_indifferent_access

      expect(replayed).to include(success: false)
      expect(replayed[:reason]).to be_nil # reached the handler, not refused for permission
      expect(acted).to be_empty
    end

    it "does not drain another account's instance even when its id is parked" do
      foreign = create(:system_node_instance, :running, node: other_node)
      result = run(FLEET_D, { action: "system_drain_instance", instance_id: foreign.id },
                   user: user_with("system.instances.control", FLEET_D::REQUIRED_PERMISSION))

      expect(result.dig(:data, :pending)).to be(true)
      replayed = approve!(result).result.with_indifferent_access
      expect(replayed).to include(success: false)
      expect(acted).to be_empty
    end

    it "does not recycle another account's pool even when its id is parked" do
      foreign = pool_in(other)
      result = run(FLEET_D, { action: "system_recycle_pool", pool_id: foreign.id },
                   user: user_with("system.instances.control", FLEET_D::REQUIRED_PERMISSION))

      expect(result.dig(:data, :pending)).to be(true)
      replayed = approve!(result).result.with_indifferent_access

      expect(replayed).to include(success: false)
      expect(replayed[:reason]).to be_nil
      expect(acted).to be_empty
    end
  end

  # The op-discriminated twin of system_drain_instance. Only op=drain_instance
  # meets the gate (`ungated_when`); scale and failover_check keep their behaviour.
  describe "system_platform_resilience op=drain_instance" do
    let(:perms) { [ "system.platform.scale", "system.instances.control", FLEET_D::REQUIRED_PERMISSION ] }
    let(:caller_user) { user_with(*perms) }
    let(:instance) { create(:system_node_instance, :running, node: node) }
    let(:params) { { action: "system_platform_resilience", op: "drain_instance", instance_id: instance.id } }

    it "declares the drain category, DeferredToolCall, and an ungated_when arm" do
      decl = FLEET_D.declared_action("system_platform_resilience")
      expect(decl).to include(action_category: "system.instance_drain", executor_class: "Ai::Executors::DeferredToolCall",
                              gate_context: :platform_resilience_drain_gate_context,
                              on_proceed: :deferred_tool_call_result,
                              ungated_when: :platform_resilience_not_drain?)
    end

    it "parks, stopping nothing" do
      parked = run(FLEET_D, params, user: caller_user)

      expect_parked_op(parked)
      expect(acted).to be_empty
    end

    it "parks the legacy resilience_action alias too" do
      parked = run(FLEET_D, { action: "system_platform_resilience", resilience_action: "drain_instance",
                              instance_id: instance.id }, user: caller_user)

      expect_parked_op(parked)
      expect(acted).to be_empty
    end

    it "drains on a single approval, as the original caller" do
      parked = run(FLEET_D, params, user: caller_user)

      operation = approve!(parked)

      expect(operation.status).to eq("completed")
      expect(operation.result.with_indifferent_access).not_to include(success: false)
      expect(acted).to eq([ [ :stop, instance.id, :stop ] ])
      expect(Ai::DeferredOperation.count).to eq(1)
    end

    it "refuses, parking nothing, a caller lacking system.instances.control" do
      denied = run(FLEET_D, params, user: user_with("system.platform.scale", FLEET_D::REQUIRED_PERMISSION))

      expect(denied[:success]).to be(false)
      expect(denied[:error]).to match(/system\.instances\.control/)
      expect(Ai::DeferredOperation.count).to eq(0)
    end

    it "refuses an agent principal with no user, parking nothing" do
      denied = run(FLEET_D, params, user: nil, agent: create(:ai_agent, account: account))

      expect(denied[:success]).to be(false)
      expect(Ai::DeferredOperation.count).to eq(0)
    end

    it "does not drain once system.instances.control was revoked after parking" do
      parked = run(FLEET_D, params, user: caller_user)
      revoke!(caller_user, "system.instances.control")

      operation = approve!(parked)

      expect(acted).to be_empty
      expect(operation.result.with_indifferent_access).to include(success: false)
    end

    it "does not drain another account's instance even when its id is parked" do
      other = create(:account)
      other_node = create(:system_node, account: other,
                          node_template: create(:system_node_template, account: other,
                                                node_platform: create(:system_node_platform, account: other)))
      foreign = create(:system_node_instance, :running, node: other_node)
      parked = run(FLEET_D, params.merge(instance_id: foreign.id), user: caller_user)

      expect(parked.dig(:data, :pending)).to be(true)
      replayed = approve!(parked).result.with_indifferent_access

      expect(replayed).to include(success: false)
      expect(acted).to be_empty
    end

    %w[scale failover_check].each do |op|
      it "leaves op=#{op} ungated: it reaches the executor inline and parks nothing" do
        seen = []
        allow_any_instance_of(::System::Ai::Skills::PlatformResilienceExecutor).to receive(:execute) do |_ex, **kw|
          seen << kw[:action]
          { success: true, data: { ok: true } }
        end

        result = run(FLEET_D, { action: "system_platform_resilience", op: op, deployment_id: SecureRandom.uuid },
                     user: caller_user)

        expect(result).to include(success: true)
        expect(result.dig(:data, :pending)).to be_nil
        expect(seen).to eq([ op ])
        expect(Ai::DeferredOperation.count).to eq(0)
      end
    end

    # Not expect_parked: the wrapper cannot be declared `destructive:` (the
    # deny-overlay equality lint holds that set equal to DESTRUCTIVE_TOOL_PATTERNS,
    # which names no "platform_resilience"), so unlike system_drain_instance its
    # approval does not require the approver's own session.
    def expect_parked_op(parked)
      expect(parked).to include(success: true)
      expect(parked[:data]).to include(pending: true)
      operation = Ai::DeferredOperation.find(parked[:data][:deferred_operation_id])
      expect(operation.action_category).to eq("system.instance_drain")
      expect(operation.executor_class).to eq("Ai::Executors::DeferredToolCall")
      expect(operation.params.to_json).to include(instance.id)
    end
  end

  describe "nothing is held any more" do
    CASES_D.each do |c|
      it "no longer lists #{c[:action]} on the agents' denied list" do
        expect(Ai::ClaudeExport::ThinLoader::DENIED_DESTRUCTIVE_ACTIONS).not_to include(c[:action])
      end
    end
  end
end
