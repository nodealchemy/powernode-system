# frozen_string_literal: true

require "rails_helper"

# APO-1a (IMP-1e58753b3b6c) — the hazard this increment had to avoid.
#
# Ai::Tools::BaseTool#execute routes a GATED declaration to Ai::AutonomyGate
# BEFORE #call. SystemFleetTool enforces its per-action permissions INSIDE
# #call (#action_permitted?), so declaring one of its write verbs in a way that
# arms the gate would DELETE that permission check — a privilege escalation
# introduced by a safety control (see the same warning at base_tool.rb's
# `refusal = authorization_error(params)`).
#
# The declarations added by APO-1a carried `mutating:` only. BaseTool#gated_action?
# additionally requires action_category + executor_class + gate_context +
# on_proceed, so those declarations did NOT arm the gate: #execute fell through
# to `return call(params)` and the permission check still ran.
#
# WHAT CHANGED SINCE (HIER-P2B-ENG): two of the verbs below — system_promote_
# module_version and system_deploy_platform — ARE now gate-routed, on
# release.promote / release.deploy_platform. The examples here are unchanged and
# still green, but they now assert a DIFFERENT (and stronger) property for
# those two, which is why this note exists rather than a silently-passing file:
#
#   * promote reaches the gate not at all, because BaseTool evaluates the tool's
#     own `authorization_error` BEFORE routing a gated action — the hoisted
#     pre-gate refusal that keeps #action_permitted? load-bearing for a gated
#     verb. An unauthorized caller is refused, never parked.
#   * deploy_platform with no `mode` takes the declaration's `ungated_when` READ
#     arm (the wizard card provisions nothing, so parking it as an approval
#     would be wrong) and dispatches into #call, where the same permission check
#     refuses it.
#
# So the invariant this file defends is intact and now reads: an unauthorized
# caller of ANY of these verbs is refused by the permission check, and gating a
# verb never converts that refusal into an approval request. The two remaining
# entries (delete_node, destroy_instance) are still ungated declarations.
#
# system_terminate_instance is deliberately NOT in this list: it was already
# gate-routed before APO-1a (IMP-d410a587d6bf) and keeps that behaviour. It is
# no longer the ONLY gate-routed action on this tool — the live census lives in
# server/spec/services/ai/tools/action_declaration_completeness_spec.rb
# (GATE_ROUTED_ACTIONS), which is where a count belongs.
RSpec.describe Ai::Tools::SystemFleetTool, "APO-1a declarations are non-enforcing" do
  let(:account) { create(:account) }
  let(:nobody)  { create(:user, account: account, permissions: []) }

  # (action, the permission #call demands) — one write verb from each family
  # the offer named as running ungated from MCP. promote_module_version and
  # deploy_platform are gate-routed as of HIER-P2B-ENG (see the header); they
  # stay in the list because the property asserted — an unauthorized caller is
  # REFUSED, never parked — is exactly what must survive gating.
  NEWLY_DECLARED_WRITES = {
    "system_delete_node" => "system.nodes.delete",
    "system_destroy_instance" => "system.instances.control",
    "system_promote_module_version" => "system.modules.update",
    "system_deploy_platform" => "system.platform.deploy"
  }.freeze

  def tool = described_class.new(account: account, user: nobody)

  it "declares each of them mutating" do
    NEWLY_DECLARED_WRITES.each_key do |action|
      declaration = described_class.declared_action(action)

      expect(declaration).not_to be_nil, "#{action} carries no declaration"
      expect(declaration[:mutating]).to be(true), "#{action} is declared mutating: false"
    end
  end

  it "still refuses an unauthorized caller with the SAME permission_denied result" do
    NEWLY_DECLARED_WRITES.each do |action, permission|
      result = tool.execute(params: { action: action }.with_indifferent_access)

      expect(result[:success]).to be(false), "#{action} did not refuse"
      expect(result[:error]).to eq("permission denied: #{permission} required"),
                                "#{action} refused with an unexpected message"
    end
  end

  # Two of them are gate-routed now; NONE of them reaches the gate for an
  # unauthorized caller. That is the property, and it holds for both reasons
  # the header names (the hoisted pre-gate refusal, and the declared read arm).
  it "never reaches the autonomy gate for any of them" do
    expect(Ai::AutonomyGate).not_to receive(:evaluate)

    NEWLY_DECLARED_WRITES.each_key do |action|
      tool.execute(params: { action: action }.with_indifferent_access)
    end
  end

  # Names which of them are gated TODAY, so the file cannot go on describing a
  # surface it no longer has: a verb that gains or loses gate routing turns this
  # red rather than quietly re-purposing the examples above.
  it "records which of these verbs are gate-routed today" do
    gated = NEWLY_DECLARED_WRITES.keys.select do |action|
      d = described_class.declared_action(action)
      d[:action_category].present? && d[:executor_class].present? &&
        d[:gate_context].present? && d[:on_proceed].present?
    end

    expect(gated).to contain_exactly("system_promote_module_version", "system_deploy_platform")
  end

  it "keeps system_terminate_instance, gate-routed since before APO-1a, gate-routed" do
    declaration = described_class.declared_action("system_terminate_instance")

    expect(declaration[:mutating]).to be(true)
    expect(declaration[:executor_class]).to eq("System::Executors::TerminateInstance")
    expect(declaration[:gate_context]).to eq(:terminate_instance_gate_context)
  end
end
