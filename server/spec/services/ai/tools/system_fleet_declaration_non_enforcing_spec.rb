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
# The declarations added by APO-1a carry `mutating:` only. BaseTool#gated_action?
# additionally requires action_category + executor_class + gate_context +
# on_proceed, so those declarations do NOT arm the gate: #execute still falls
# through to `return call(params)` and the permission check still runs. This
# file asserts that end-to-end, against the ROW that would have moved, not just
# against the declaration hash — the declared verbs below are all newly declared
# mutating: true and all still refuse an unauthorized caller exactly as before.
#
# system_terminate_instance is deliberately NOT in this list: it was already
# gate-routed before this increment (IMP-d410a587d6bf) and keeps that behaviour.
RSpec.describe Ai::Tools::SystemFleetTool, "APO-1a declarations are non-enforcing" do
  let(:account) { create(:account) }
  let(:nobody)  { create(:user, account: account, permissions: []) }

  # (action, the permission #call demands) — one write verb from each family
  # the offer named as running ungated from MCP.
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

  it "never reaches the autonomy gate for any of them" do
    expect(Ai::AutonomyGate).not_to receive(:evaluate)

    NEWLY_DECLARED_WRITES.each_key do |action|
      tool.execute(params: { action: action }.with_indifferent_access)
    end
  end

  it "keeps the one pre-existing gate-routed action gate-routed" do
    declaration = described_class.declared_action("system_terminate_instance")

    expect(declaration[:mutating]).to be(true)
    expect(declaration[:executor_class]).to eq("System::Executors::TerminateInstance")
    expect(declaration[:gate_context]).to eq(:terminate_instance_gate_context)
  end
end
