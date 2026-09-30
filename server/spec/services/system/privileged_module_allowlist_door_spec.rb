# frozen_string_literal: true

require "rails_helper"

# IMP-06cf44531256 — the write door for the privileged-module grant, exercised
# end to end. The grant switches all on-node confinement off for a module, so
# the assertion that matters is the ROW: what the setting holds after each
# attempt, not the shape of an envelope.
RSpec.describe "site_setting_set_protected writes the privileged-module allowlist" do
  let(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, permissions: [ "admin.access" ]) }
  let(:confirmer) { create(:user, account: account, permissions: [ "admin.access", "ai.autonomy.approve" ]) }
  let(:node_module) { create(:system_node_module, account: account) }
  let(:tool) { ::Ai::Tools::SiteSettingTool.new(account: account, user: admin) }
  let(:node_instance) { double("NodeInstance", id: "bb11cc22-0000-4000-8000-000000000003", account: account) }

  after { ::Mcp::Principal.reset! }

  def key = System::PrivilegedModuleAllowlist::SETTING_KEY

  def request_write(value)
    tool.execute(params: { action: "site_setting_set_protected", key: key, value: value })
  end

  def approve!(parked, origin: ::Ai::ApprovalDecision::REST_SESSION)
    operation = ::Ai::DeferredOperation.find(parked.dig(:data, :deferred_operation_id))
    ::Ai::Autonomy::ApprovalWorkflowService.new(account: account)
                                           .approve(request: operation.approval_request, approver: confirmer, origin: origin)
  end

  it "parks a valid grant and writes nothing until a person confirms it" do
    parked = request_write([ node_module.id ].to_json)

    expect(parked.dig(:data, :pending)).to be(true), parked.inspect
    expect(SiteSetting.find_by(key: key)).to be_nil
    expect(System::PrivilegedModuleAllowlist.configured_ids).to eq([])
  end

  it "grants only after the human-session approval, and records the write" do
    parked = request_write([ node_module.id ].to_json)

    expect(approve!(parked, origin: "mcp_oauth")).to be(false)
    expect(System::PrivilegedModuleAllowlist.configured_ids).to eq([])

    expect(approve!(parked)).to be(true)
    expect(System::PrivilegedModuleAllowlist.configured_ids).to eq([ node_module.id.to_s ])
    expect(SiteSetting.find_by(key: key).is_public).to be(false)
  end

  it "refuses the ordinary policy-gated verb: it cannot be granted under an auto_approve policy" do
    ::Ai::InterventionPolicy.create!(account: account, action_category: "platform.site_setting.write",
                                     scope: "global", policy: "auto_approve", priority: 5, is_active: true)

    result = tool.execute(params: { action: "site_setting_set", key: key, value: [ node_module.id ].to_json })

    expect(result[:success]).to be(false)
    expect(SiteSetting.find_by(key: key)).to be_nil
  end

  it "does not let the value check be dodged by approval: a bad parked value never lands" do
    [ %(["a-name"]), [ SecureRandom.uuid ].to_json, "not json" ].each do |bad|
      parked = request_write(bad)
      approve!(parked) if parked.dig(:data, :deferred_operation_id)

      expect(SiteSetting.find_by(key: key)).to be_nil, "#{bad} landed"
    end
  end

  it "refuses an instance principal even one whose grant names the verb: the key is not machine-parkable" do
    ::Mcp::Principal.instance_resolver = ->(cn) { cn == node_instance.id ? node_instance : nil }
    ::Mcp::Principal.tool_grant_resolver = ->(_instance) { [ "platform.site_setting_set_protected" ] }
    Rails.cache.clear
    node_tool = ::Ai::Tools::SiteSettingTool.new(account: account, internal: false)
    node_tool.instance_authorized = true
    node_tool.node_instance = node_instance
    node_tool.call_origin = "mcp_instance"

    result = node_tool.execute(params: { action: "site_setting_set_protected", key: key, value: [ node_module.id ].to_json })

    expect(result[:success]).to be(false)
    expect(result[:error]).to match(/machine_parkable|only a person/)
    expect(::Ai::ApprovalRequest.count).to eq(0)
    expect(SiteSetting.find_by(key: key)).to be_nil
  end

  it "never serves the value over MCP: the read verb refuses a protected key" do
    SiteSetting.set(key, [ node_module.id ].to_json, setting_type: "json")

    result = tool.execute(params: { action: "site_setting_get", key: key })

    expect(result[:success]).to be(false)
    expect(result.to_json).not_to include(node_module.id.to_s)
  end
end
