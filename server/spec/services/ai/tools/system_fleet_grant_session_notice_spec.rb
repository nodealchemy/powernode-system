# frozen_string_literal: true

require "rails_helper"

# IMP-7f01dfcb13e0 — the grant response must say out loud that a CONNECTED MCP
# session keeps its cached tools/list until it re-lists or reconnects.
#
# The notification (see node_instance_peer_mcp_grant_notification_spec.rb) is
# correct per the MCP protocol and harmless to a client that ignores it, but
# whether any given client acts on `notifications/tools/list_changed` cannot be
# established from inside this codebase. The response text is truthful either
# way, and is the only accurate message if some clients re-list and others do
# not — so it ships alongside the notification, not instead of it.
RSpec.describe Ai::Tools::SystemFleetTool, "instance MCP grant session notice" do
  let(:account) { create(:account) }
  let(:tool)    { described_class.new(account: account, internal: true) }

  def announce
    inst = create(:system_node_instance, account: account, status: "running")
    System::NodeInstancePeer.create!(
      node_instance: inst, account: inst.node.account,
      handle: "p-#{SecureRandom.hex(3)}", status: "active", enabled: true,
      trust_score: 0.5, daily_decision_budget: 10
    )
    inst
  end

  def grant(inst, patterns, mode: nil)
    params = { action: "system_grant_instance_mcp_tools", instance_id: inst.id, tool_patterns: patterns }
    params[:mode] = mode if mode
    tool.execute(params: params)
  end

  it "names the reconnect requirement when a grant is widened" do
    inst = announce
    r = grant(inst, %w[platform.health], mode: "add")

    expect(r[:success]).to be true
    expect(r[:data][:session_notice]).to be_present
    expect(r[:data][:session_notice]).to match(/reconnect/i)
    expect(r[:data][:session_notice]).to match(/tools\/list/i)
  end

  it "names it on a narrowing grant too — a stale catalog advertises what was removed" do
    inst = announce
    grant(inst, %w[platform.health platform.metrics])
    r = grant(inst, %w[platform.health])

    expect(r[:success]).to be true
    expect(r[:data][:granted_mcp_tools]).to eq(%w[platform.health])
    expect(r[:data][:session_notice]).to match(/reconnect/i)
  end

  it "does not attach the notice to a failed grant" do
    inst = create(:system_node_instance, account: account, status: "running")
    r = grant(inst, %w[platform.health])

    expect(r[:success]).to be false
    expect(r[:data]).to be_nil
  end
end
