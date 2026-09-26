# frozen_string_literal: true

require "rails_helper"

# Flipping a plane to PINNED must freeze every module where it stands, whatever
# door the flip came through. A pinned plane with no pin serves NOTHING of a
# module (NodeModule#served_version_for), so a flip that lands without its
# freeze tells every node on that plane that none of its modules exist.
#
# Observed on a live control plane 2026-09-23: environment_update (human-only,
# approved from the operator's own session) set ops.auto_promote_on_publish to
# false and zero ModuleEnvironmentPin rows were written.
RSpec.describe "environment_update freezes pins when it pins a plane" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:mod)      { create(:system_node_module, account: account, node_platform: platform, category: category, name: "hub-backend") }
  let(:ops)      { account.environments.find_by!(slug: "ops") }
  let(:approver) do
    create(:user, account: account, permissions: [ "ai.governance.manage", "ai.governance.read", "ai.autonomy.approve" ])
  end
  let!(:v1) do
    v = create(:system_node_module_version, node_module: mod, version_number: 1,
                                            artifacts: { "erofs" => { "oci_digest" => "sha256:#{'1' * 64}", "size" => 1, "oci_ref" => "r1" } },
                                            oci_digest: "sha256:#{'1' * 64}")
    mod.promote_to_version!(v)
    v
  end

  it "freezes on a direct model update (the listener works)" do
    ops.update!(auto_promote_on_publish: false)
    expect(mod.environment_pins.find_by(environment: ops)).to have_attributes(node_module_version: v1)
  end

  it "freezes when the flip is an approved human-only environment_update replay" do
    instance_tool = Ai::Tools::EnvironmentTool.new(account: account)
    instance_tool.call_origin = Ai::Tools::CallOrigin::MCP_INSTANCE
    instance_tool.instance_authorized = true
    parked = instance_tool.execute(params: { "action" => "environment_update", "environment" => "ops",
                                             "auto_promote_on_publish" => false }.with_indifferent_access)
    operation = Ai::DeferredOperation.find(parked.dig(:data, :deferred_operation_id))

    expect(Ai::Autonomy::ApprovalWorkflowService.new(account: account)
             .approve(request: operation.approval_request, approver: approver,
                      origin: Ai::ApprovalDecision::REST_SESSION)).to be(true)

    expect(ops.reload.follows_publish?).to be(false)
    expect(mod.served_version_for(ops)).to eq(v1)
    expect(mod.environment_pins.find_by(environment: ops)).to have_attributes(node_module_version: v1,
                                                                              promoted_by_type: "pin_freeze")
  end
end
