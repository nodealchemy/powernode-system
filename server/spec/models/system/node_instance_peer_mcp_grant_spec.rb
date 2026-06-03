# frozen_string_literal: true

require "rails_helper"

# AI/MCP workload substrate L2 — per-instance MCP tool grant (default-deny).
RSpec.describe System::NodeInstancePeer, type: :model do
  let(:account) { create(:account) }
  let(:instance) { create(:system_node_instance, account: account, status: "running") }
  let(:peer) do
    described_class.create!(
      node_instance: instance, account: instance.node.account,
      handle: "agent-#{SecureRandom.hex(3)}", status: "active",
      trust_score: 0.5, daily_decision_budget: 10
    )
  end

  it "defaults granted_mcp_tools to an empty array (default-deny)" do
    expect(peer.granted_mcp_tools).to eq([])
  end

  describe "#grant_mcp_tools!" do
    it "replaces the granted patterns by default" do
      peer.grant_mcp_tools!(%w[platform.health platform.system_*_read])
      expect(peer.reload.granted_mcp_tools).to contain_exactly("platform.health", "platform.system_*_read")

      peer.grant_mcp_tools!(%w[platform.metrics])
      expect(peer.reload.granted_mcp_tools).to eq(%w[platform.metrics])
    end

    it "unions when mode: :add" do
      peer.grant_mcp_tools!(%w[platform.health])
      peer.grant_mcp_tools!(%w[platform.metrics platform.health], mode: :add)
      expect(peer.reload.granted_mcp_tools).to contain_exactly("platform.health", "platform.metrics")
    end

    it "strips blanks and dedups" do
      peer.grant_mcp_tools!(["platform.health", "", "platform.health", " "])
      expect(peer.reload.granted_mcp_tools).to eq(%w[platform.health])
    end
  end
end
