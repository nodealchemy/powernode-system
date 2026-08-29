# frozen_string_literal: true

require "rails_helper"

# IMP-7f01dfcb13e0 — an MCP client caches tools/list at connect. The protocol's
# only invalidation mechanism is `notifications/tools/list_changed`, and the
# platform already ships the machinery (Mcp::SessionNotifier). The instance
# grant path never fired it, so a correct grant appeared to do nothing until an
# out-of-band reconnect — and the platform's own recorded recovery procedure
# ("a missing tool is an instance-grant gap — grant it with mode: add") looked
# like it had failed.
#
# CORRECTNESS, not privilege: Mcp::Principal re-reads the stored grant on every
# call, so a stale catalog never lets a narrowed session INVOKE anything it lost.
# The failure mode is wrong: tools advertised but rejected, tools granted but
# invisible.
#
# ORACLE SHAPE: these assert the TERMINAL broadcast (the pubsub channel and the
# exact JSON on it), not that some named method was called — a notifier wired to
# a method that broadcasts nothing would pass a "receives" assertion.
RSpec.describe System::NodeInstancePeer, "MCP tool-catalog invalidation" do
  let(:account) { create(:account) }
  let(:instance) { create(:system_node_instance, account: account, status: "running") }
  let(:peer) do
    described_class.create!(
      node_instance: instance, account: instance.node.account,
      handle: "p-#{SecureRandom.hex(3)}", status: "active", enabled: true,
      trust_score: 0.5, daily_decision_budget: 10
    )
  end

  # A connected MCP session for this account, as the mTLS instance lane records
  # one (no User — principal_kind/principal_subject_id instead).
  let!(:session) do
    McpSession.create!(
      account: account, principal_kind: "instance", principal_subject_id: instance.id,
      session_token: "tok-#{SecureRandom.hex(6)}", status: "active",
      expires_at: 1.hour.from_now
    )
  end

  # Capture what actually reaches the pubsub bus during the block.
  def broadcasts_during
    captured = []
    allow(ActionCable.server.pubsub).to receive(:broadcast) { |ch, msg| captured << [ ch, msg ] }
    yield
    captured
  end

  def tool_list_changed(captured)
    captured.select { |(_, msg)| msg.to_s.include?("notifications/tools/list_changed") }
  end

  it "invalidates the connected session's catalog when a grant is WIDENED" do
    peer.grant_mcp_tools!(%w[platform.health], mode: :replace)

    captured = broadcasts_during do
      peer.grant_mcp_tools!(%w[platform.update_ralph_loop], mode: :add)
    end

    hits = tool_list_changed(captured)
    expect(hits.size).to eq(1)
    expect(hits.first[0]).to eq("mcp_session:#{session.session_token}")
  end

  it "invalidates the connected session's catalog when a grant is NARROWED" do
    peer.grant_mcp_tools!(%w[platform.health platform.metrics], mode: :replace)

    captured = broadcasts_during do
      peer.grant_mcp_tools!(%w[platform.health], mode: :replace)
    end

    expect(tool_list_changed(captured).size).to eq(1)
  end

  it "invalidates the connected session's catalog on a full REVOCATION" do
    peer.grant_mcp_tools!(%w[platform.health], mode: :replace)

    captured = broadcasts_during do
      peer.grant_mcp_tools!([], mode: :replace)
    end

    expect(tool_list_changed(captured).size).to eq(1)
  end

  it "fires for a direct attribute write, not only for the grant helper" do
    peer.grant_mcp_tools!(%w[platform.health], mode: :replace)

    captured = broadcasts_during do
      peer.update!(granted_mcp_tools: %w[platform.health platform.metrics])
    end

    expect(tool_list_changed(captured).size).to eq(1)
  end

  it "stays silent when the grant set does not actually change" do
    peer.grant_mcp_tools!(%w[platform.health], mode: :replace)

    captured = broadcasts_during do
      peer.grant_mcp_tools!(%w[platform.health], mode: :add)
      peer.record_execution!(success: true)
    end

    expect(tool_list_changed(captured)).to be_empty
  end

  # SCOPING: Mcp::SessionNotifier addresses an ACCOUNT, while the grant is
  # per-instance. That is deliberate (a re-list is cheap and idempotent, and the
  # session→instance mapping is not addressable from here), but it must not turn
  # the channel into a disclosure of which instances exist. The payload carries
  # no params at all, so a sibling session learns only "re-list", never who.
  it "carries no instance, peer, or grant identifiers in the payload" do
    captured = broadcasts_during do
      peer.grant_mcp_tools!(%w[platform.health], mode: :replace)
    end

    payload = tool_list_changed(captured).first[1]
    expect(JSON.parse(payload)).to eq("jsonrpc" => "2.0", "method" => "notifications/tools/list_changed")
    expect(payload).not_to include(instance.id, peer.id, peer.handle, "platform.health")
  end
end
