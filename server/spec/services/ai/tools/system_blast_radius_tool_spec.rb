# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Tools::SystemBlastRadiusTool do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account, permissions: [ "system.nodes.read" ]) }
  let(:tool)    { described_class.new(account: account, user: user) }

  describe ".definition" do
    it "exposes a single required 'node' string parameter and no leftover :action key" do
      params = described_class.definition[:parameters]

      expect(params.keys).to eq(%i[node])
      expect(params[:node][:required]).to be true
    end
  end

  describe "#execute" do
    it "delegates to System::BlastRadiusService and returns its result verbatim" do
      node = create(:system_node, account: account, name: "ops-hub")
      instance = create(:system_node_instance, node: node)
      create(:sdwan_peer, account: account, node_instance: instance)

      result = tool.execute(params: { node: "ops-hub" })

      expect(result[:success]).to be true
      expect(result[:target][:kind]).to eq("node")
      expect(result[:dependents]["sdwan_peers"][:count]).to eq(1)
    end

    it "raises the standard BaseTool missing-required-parameter error when node is omitted" do
      expect { tool.execute(params: {}) }.to raise_error(ArgumentError, /node/)
    end

    it "returns a not-found result (not an exception) for an unresolvable identifier" do
      result = tool.execute(params: { node: "no-such-node-anywhere" })

      expect(result[:success]).to be false
      expect(result[:error]).to include("no-such-node-anywhere")
    end
  end

  describe "registry wiring" do
    it "is discoverable via PlatformApiToolRegistry under its own action name" do
      expect(Ai::Tools::PlatformApiToolRegistry.find_tool("system_blast_radius")).to eq(described_class)
    end

    it "requires no :action injection (single-action tool)" do
      needs_action = described_class.definition[:parameters]&.key?(:action) ||
                     described_class.action_definitions.size > 1

      expect(needs_action).to be false
    end
  end

  describe "permission gate" do
    it "is gated by system.nodes.read" do
      expect(described_class::REQUIRED_PERMISSION).to eq("system.nodes.read")
    end
  end
end
