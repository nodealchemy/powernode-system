# frozen_string_literal: true

require "rails_helper"

# IMP-1765f6f09458 — the ssh host-key switch is machine-parkable, and a machine
# may only TIGHTEN it. The engine registers the ordering: true (refuse a node
# with no recorded host key) is stricter than false, and unset reads as false.
# So an instance may ask to turn verification ON, and may never ask to turn it
# OFF while it is on. A person is not bound.
RSpec.describe "system.ssh.require_host_key: a machine may only tighten it" do
  let(:account) { create(:account) }
  let!(:operator) { create(:user, account: account, permissions: [ "admin.access", "ai.autonomy.approve" ]) }
  let(:node_instance) { double("NodeInstance", id: "bb11cc22-0000-4000-8000-000000000005", account: account) }
  let(:key) { ::System::SshExecutionService::REQUIRE_HOST_KEY_SETTING }

  before do
    Rails.cache.clear
    ::Mcp::Principal.instance_resolver = ->(cn) { cn == node_instance.id ? node_instance : nil }
    ::Mcp::Principal.tool_grant_resolver = ->(_instance) { [ "platform.site_setting_set_protected" ] }
  end

  after { ::Mcp::Principal.reset! }

  def park(value)
    tool = ::Ai::Tools::SiteSettingTool.new(account: account)
    tool.instance_authorized = true
    tool.node_instance = node_instance
    tool.call_origin = "mcp_instance"
    Rails.cache.clear
    tool.execute(params: { action: "site_setting_set_protected", key: key, value: value })
  end

  def last_refusal_reason
    AuditLog.where(action: "ai.approvals.machine_park_refused").order(:created_at).last&.metadata&.fetch("reason", nil)
  end

  it "is registered protected, machine-parkable and with an ordering, from the service's own constant" do
    spec = ::Ai::Tools::SiteSettingTool.operator_configurable_keys[key]

    expect(spec).to include(setting_type: "boolean", protected: true, machine_parkable: true)
    expect(::Ai::Tools::SiteSettingTool.machine_park_orderings[key]).to respond_to(:call)
  end

  it "parks turning verification ON, from unset and from off" do
    expect(park("true").dig(:data, :pending)).to be(true)
    expect(SiteSetting.find_by(key: key)).to be_nil

    SiteSetting.set(key, "false", setting_type: "boolean")
    Ai::ApprovalRequest.update_all(status: "rejected")
    expect(park("true").dig(:data, :pending)).to be(true)
  end

  it "parks OFF only while it is not on: unset reads as off, so that tightens nothing and is accepted" do
    expect(park("false").dig(:data, :pending)).to be(true)
  end

  it "refuses turning verification OFF while it is on, and parks nothing" do
    SiteSetting.set(key, "true", setting_type: "boolean")

    result = park("false")

    expect(result[:success]).to be(false)
    expect(result[:error]).to include("only tighten")
    expect(last_refusal_reason).to eq("not_tightening")
    expect(Ai::ApprovalRequest.count).to eq(0)
    expect(::System::SshExecutionService.require_host_key?).to be(true)
  end

  it "leaves a person free to turn it off: the ordering binds machines only" do
    SiteSetting.set(key, "true", setting_type: "boolean")
    tool = ::Ai::Tools::SiteSettingTool.new(account: account, user: operator)
    tool.call_origin = "mcp_oauth"

    result = tool.execute(params: { action: "site_setting_set_protected", key: key, value: "false" })

    expect(result.dig(:data, :pending)).to be(true)
    request = Ai::ApprovalRequest.find(result[:data][:approval_request_id])
    expect(request.machine_requested?).to be(false)
    Ai::Autonomy::ApprovalWorkflowService.new(account: account)
                                         .approve(request: request, approver: operator, origin: Ai::ApprovalDecision::REST_SESSION)
    expect(::System::SshExecutionService.require_host_key?).to be(false)
  end
end
