# frozen_string_literal: true

require "rails_helper"

# AI/MCP workload substrate L2.5 (A2A) — per-instance peer-skill grant + the
# offered-skill projection used by capability discovery. Default-deny.
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

  it "defaults granted_peer_skills to an empty array (default-deny)" do
    expect(peer.granted_peer_skills).to eq([])
    expect(peer.may_invoke_peer_skill?("anything")).to be(false)
  end

  describe "#grant_peer_skills!" do
    it "replaces the granted patterns by default" do
      peer.grant_peer_skills!(%w[embed-* summarize])
      expect(peer.reload.granted_peer_skills).to contain_exactly("embed-*", "summarize")

      peer.grant_peer_skills!(%w[translate])
      expect(peer.reload.granted_peer_skills).to eq(%w[translate])
    end

    it "unions when mode: :add" do
      peer.grant_peer_skills!(%w[embed])
      peer.grant_peer_skills!(%w[summarize embed], mode: :add)
      expect(peer.reload.granted_peer_skills).to contain_exactly("embed", "summarize")
    end

    it "strips blanks and dedups" do
      peer.grant_peer_skills!([ "embed", "", "embed", " " ])
      expect(peer.reload.granted_peer_skills).to eq(%w[embed])
    end
  end

  describe "#may_invoke_peer_skill?" do
    it "matches granted glob patterns (default-deny otherwise)" do
      peer.grant_peer_skills!(%w[embed-* summarize])
      expect(peer.may_invoke_peer_skill?("embed-text")).to be(true)
      expect(peer.may_invoke_peer_skill?("summarize")).to be(true)
      expect(peer.may_invoke_peer_skill?("translate")).to be(false)
    end
  end

  describe "#offered_skill_names" do
    it "extracts names from hash-shaped declared_skills" do
      peer.update!(declared_skills: [ { "name" => "embed" }, { "name" => "summarize" } ])
      expect(peer.offered_skill_names).to contain_exactly("embed", "summarize")
    end

    it "accepts plain-string declared_skills" do
      peer.update!(declared_skills: %w[embed translate])
      expect(peer.offered_skill_names).to contain_exactly("embed", "translate")
    end

    it "is empty when nothing is declared" do
      peer.update!(declared_skills: [])
      expect(peer.offered_skill_names).to eq([])
    end
  end
end
