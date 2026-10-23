# frozen_string_literal: true

require "rails_helper"

# system_promote_module_version under a core promotion grant (Ai::PromotionGrant).
# The verb's gate context names the subject (module + pinned version) for the
# gate, and the extension's catalog tells core which permission a granter needs
# and which modules a grant may name. The ops plane is protected and its
# release.promote row parks; a matching grant lets THIS agent promote anyway.
RSpec.describe Ai::Tools::SystemFleetTool, "promotion grants" do
  let(:account)  { create(:account) }
  let!(:operator) { create(:user, account: account, permissions: %w[system.nodes.read system.modules.update]) }
  let(:agent)    { create(:ai_agent, account: account, name: "Claude Code (headersHelper) #13", agent_type: "mcp_client") }
  # The live call shape: a person's MCP OAuth session whose client agent is
  # the MCP-client identity. The grant names that agent.
  let(:tool)     { described_class.new(account: account, user: operator, agent: agent, call_origin: "mcp_oauth") }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:mod)      { create(:system_node_module, account: account, node_platform: platform, category: category, name: "hub-backend") }
  let(:staging)  { account.environments.find_by!(slug: "staging") }
  let(:ops)      { account.environments.find_by!(slug: "ops") }

  let!(:v1) do
    create(:system_node_module_version, node_module: mod, version_number: 1,
           artifacts: { "erofs" => { "oci_digest" => "sha256:#{'1' * 64}", "size" => 12_345_000, "oci_ref" => "ref1" } })
  end

  before do
    ops.update!(auto_promote_on_publish: false)
    mod.promote_to_version!(v1)
    mod.promote_in_environment!(environment: staging, version: v1, actor: operator)
    Ai::InterventionPolicy.create!(account: account, scope: "global", action_category: "release.promote",
                                   policy: "require_approval", priority: 60, conditions: { "environments" => [ "ops" ] })
  end

  def promote
    tool.execute(params: { action: "system_promote_module_version", module_id: mod.id, environment: "ops",
                           version_id: v1.id }.with_indifferent_access)
  end

  it "parks the ops promotion when no grant exists" do
    expect(promote.dig(:data, :pending)).to be(true)
    expect(mod.served_version_for(ops)).to be_nil
  end

  it "promotes under a matching grant, names the grant, and audits module, version and plane" do
    grant = create(:ai_promotion_grant, account: account, granted_by: operator, agent: agent, environment: ops,
                                        module_ids: [ mod.id ], max_uses: 1)

    result = promote

    expect(result[:success]).to be(true)
    expect(result.dig(:data, :pending)).to be_nil
    expect(result[:promotion_grant]).to include(id: grant.id, uses_count: 1, max_uses: 1)
    expect(mod.served_version_for(ops)).to eq(v1)

    audit = AuditLog.where(account_id: account.id, action: "ai.promotion_grant.used").sole
    expect(audit.metadata).to include("module_id" => mod.id, "version_id" => v1.id, "environment_slug" => "ops",
                                      "ai_agent_id" => agent.id, "target_environment_id" => ops.id,
                                      "driving_user_id" => operator.id, "call_origin" => "mcp_oauth")
    expect(promote.dig(:data, :pending)).to be(true) # max_uses spent
  end

  it "declares the catalog core reads: the verb's permission and this account's modules" do
    catalog = Ai::PromotionGrants::Catalog
    expect(catalog.required_permission("release.promote")).to eq("system.modules.update")
    expect(catalog.subjects(account: account, action_category: "release.promote"))
      .to include(include(id: mod.id, name: "hub-backend"))
    expect(catalog.unknown_subject_ids(account: account, action_category: "release.promote",
                                       ids: [ mod.id, SecureRandom.uuid ]).size).to eq(1)
  end

  # M-1 end to end through the agent-bridge door (Ai::AgentToolBridgeService):
  # every bridge call runs with `user: agent.creator`, so the creator stands in
  # for whoever ran the agent. granter_driven_only must key on the REAL
  # triggering user the door is handed, never on that stand-in.
  describe "through the agent-bridge door" do
    let(:runner) { create(:user, account: account, permissions: %w[system.nodes.read]) }
    let(:creators_agent) { create(:ai_agent, account: account, creator: operator, name: "Release Bot") }
    let!(:grant) do
      create(:ai_promotion_grant, account: account, granted_by: operator, agent: creators_agent, environment: ops,
                                  module_ids: [ mod.id ], granter_driven_only: true)
    end

    def bridge_promote(driving_user: :none)
      bridge = if driving_user == :none
        Ai::AgentToolBridgeService.new(agent: creators_agent, account: account)
      else
        Ai::AgentToolBridgeService.new(agent: creators_agent, account: account, driving_user: driving_user)
      end
      _json, result = bridge.dispatch_tool_call_capturing(
        name: "system_promote_module_version",
        arguments: { module_id: mod.id, environment: "ops", version_id: v1.id }
      )
      result
    end

    it "refuses the grant when someone else runs the granter's agent, and spends nothing" do
      result = bridge_promote(driving_user: runner)

      expect(result.dig(:data, :pending)).to be(true)
      expect(grant.reload.uses_count).to eq(0)
      expect(mod.served_version_for(ops)).to be_nil
    end

    it "refuses it when the door knows no driver (the creator is only a stand-in)" do
      expect(bridge_promote.dig(:data, :pending)).to be(true)
      expect(grant.reload.uses_count).to eq(0)
    end

    it "honours it when the granter runs the agent, and names the real driver" do
      result = bridge_promote(driving_user: operator)

      expect(result.dig(:data, :pending)).to be_nil
      expect(mod.served_version_for(ops)).to eq(v1)
      audit = AuditLog.where(account_id: account.id, action: "ai.promotion_grant.used").sole
      expect(audit.metadata).to include("driving_user_id" => operator.id, "driver_known" => true,
                                        "call_origin" => Ai::Tools::CallOrigin::AGENT_BRIDGE)
    end
  end

  # Round-3 M-1: the concierge confirmation reached from the TOOL door.
  # Agent A (created by the granter) runs for someone else and calls
  # confirm_concierge_action on a pending promote card. Its tool `user` is
  # the creator stand-in, so the concierge must get no driver from it.
  describe "through confirm_concierge_action on the agent-bridge door" do
    let(:conversation_perms) { %w[system.nodes.read system.modules.update ai.conversations.create ai.agents.read] }
    let!(:granter) { create(:user, account: account, permissions: conversation_perms) }
    let(:concierge) { create(:ai_agent, account: account, creator: granter, is_concierge: true, name: "Concierge") }
    let(:agent_a) { create(:ai_agent, account: account, creator: granter, name: "Agent A") }
    let(:conversation) { create(:ai_conversation, account: account, user: granter, agent: concierge) }

    def confirm_from_bridge
      Ai::Tools::McpPlatformToolRegistrar.execute_tool(
        "platform.confirm_concierge_action",
        params: { conversation_id: conversation.id, action_type: "tool_call",
                  action_params: { "_tool_name" => "system_promote_module_version", "module_id" => mod.id,
                                   "environment" => "ops", "version_id" => v1.id } },
        account: account, user: granter, mcp_agent: agent_a, origin: Ai::Tools::CallOrigin::AGENT_BRIDGE
      )
    end

    it "does not spend a granter-only grant: the stand-in creator is not the driver" do
      grant = create(:ai_promotion_grant, account: account, granted_by: granter, agent: concierge, environment: ops,
                                          module_ids: [ mod.id ], granter_driven_only: true)

      confirm_from_bridge

      expect(grant.reload.uses_count).to eq(0)
      expect(mod.served_version_for(ops)).to be_nil
    end

    it "records an unknown driver when an ordinary grant is spent" do
      create(:ai_promotion_grant, account: account, granted_by: granter, agent: concierge, environment: ops,
                                  module_ids: [ mod.id ])

      confirm_from_bridge

      audit = AuditLog.where(account_id: account.id, action: "ai.promotion_grant.used").sole
      expect(audit.metadata).to include("driver_known" => false, "driving_user_id" => nil)
      expect(audit.user_id).to be_nil
    end
  end

  # The agent-requested, session-bound grant end to end over the MCP door:
  # the agent asks through request_promotion_grant on its own session, a person
  # approves the card in their own session, and the promotion then proceeds
  # only for calls arriving on THAT session.
  describe "a session-bound grant the agent requested" do
    let!(:person) do
      create(:user, account: account, permissions: %w[system.nodes.read system.modules.update ai.agents.read
                                                      ai.autonomy.approve ai.promotion_grants.manage])
    end
    let(:session) { McpSession.create!(user: person, account: account, ai_agent: agent) }
    let(:other_session) { McpSession.create!(user: person, account: account, ai_agent: agent) }

    def over_mcp(tool_name, params, on_session:)
      Ai::Tools::McpPlatformToolRegistrar.execute_tool(
        "platform.#{tool_name}", params: params, account: account, user: person, mcp_agent: agent,
        origin: Ai::Tools::CallOrigin::MCP_OAUTH, mcp_session: on_session
      )
    end

    def promote_on(on_session)
      over_mcp("system_promote_module_version", { module_id: mod.id, environment: "ops", version_id: v1.id },
               on_session: on_session)
    end

    before do
      asked = over_mcp("request_promotion_grant",
                       { environment: "ops", module_ids: [ mod.id ], max_uses: 2, expires_in_hours: 2,
                         reason: "ship hub-backend", bind: "session" }, on_session: session)
      expect(asked[:success]).to be(true)
      grant_request = Ai::PromotionGrantRequest.find(asked[:promotion_grant_request][:id])
      approved = Ai::Autonomy::ApprovalWorkflowService.new(account: account)
                   .approve(request: grant_request.approval_request, approver: person,
                            origin: Ai::ApprovalDecision::REST_SESSION)
      expect(approved).to be(true)
      @grant = grant_request.reload.promotion_grant
    end

    it "is issued in the approver's name, bound to the requesting session" do
      expect(@grant).to have_attributes(granted_by_id: person.id, ai_agent_id: agent.id, binding_kind: "mcp_session",
                                        binding_id: session.id, module_ids: [ mod.id ], max_uses: 2)
    end

    it "parks the same agent's promotion from another session" do
      expect(promote_on(other_session).dig(:data, :pending)).to be(true)
      expect(@grant.reload.uses_count).to eq(0)
      expect(mod.served_version_for(ops)).to be_nil
    end

    it "promotes on the bound session and records the session on the use" do
      result = promote_on(session)

      expect(result.dig(:data, :pending)).to be_nil
      expect(mod.served_version_for(ops)).to eq(v1)
      audit = AuditLog.where(account_id: account.id, action: "ai.promotion_grant.used").sole
      expect(audit.metadata).to include("binding_kind" => "mcp_session", "binding_id" => session.id)
      expect(audit.metadata["principal"]).to include("mcp_session_id" => session.id)
    end

    it "parks once the session has ended" do
      session.update!(status: "expired")
      expect(promote_on(session).dig(:data, :pending)).to be(true)
      expect(@grant.reload).to be_revoked
    end
  end
end
