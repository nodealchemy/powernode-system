# frozen_string_literal: true

require "rails_helper"

# AI/MCP workload substrate L2.5 (A2A) — platform-side capability discovery +
# three-gate authorization for instance-to-instance MCP calls.
RSpec.describe System::PeerCapabilityService, type: :service do
  let(:account) { create(:account) }

  def build_peer(handle:, account: self.account, status: "active", enabled: true, declared_skills: [], granted: [])
    instance = create(:system_node_instance, account: account, status: "running")
    System::NodeInstancePeer.create!(
      node_instance: instance, account: account,
      handle: handle, status: status, enabled: enabled,
      trust_score: 0.5, daily_decision_budget: 10,
      declared_skills: declared_skills
    ).tap { |p| p.grant_peer_skills!(granted) if granted.any? }
  end

  describe ".discoverable_for" do
    it "lists online, enabled peers with their offered skills (excluding the caller)" do
      caller = build_peer(handle: "caller", granted: %w[embed])
      target = build_peer(handle: "target", declared_skills: [ { "name" => "embed" } ])
      build_peer(handle: "offline", status: "disconnected")
      build_peer(handle: "disabled", enabled: false)

      result = described_class.discoverable_for(account: account, caller_peer: caller)

      handles = result.map { |r| r[:handle] }
      expect(handles).to contain_exactly("target")
      entry = result.first
      expect(entry[:offered_skills]).to eq(%w[embed])
      expect(entry[:instance_id]).to eq(target.node_instance_id)
    end

    it "excludes peers from other accounts" do
      other = create(:account)
      build_peer(handle: "mine")
      build_peer(handle: "theirs", account: other)

      result = described_class.discoverable_for(account: account)
      expect(result.map { |r| r[:handle] }).to contain_exactly("mine")
    end
  end

  describe ".authorize" do
    it "authorizes when caller is granted, target is online/enabled, and offers the skill" do
      caller = build_peer(handle: "caller", granted: %w[embed-*])
      target = build_peer(handle: "target", declared_skills: [ { "name" => "embed-text" } ])

      decision = described_class.authorize(caller_peer: caller, target_peer: target, skill: "embed-text")
      expect(decision.authorized).to be(true)
      expect(decision.reason).to eq("ok")
    end

    it "denies when the caller has no matching grant (default-deny)" do
      caller = build_peer(handle: "caller", granted: %w[summarize])
      target = build_peer(handle: "target", declared_skills: [ { "name" => "embed" } ])

      decision = described_class.authorize(caller_peer: caller, target_peer: target, skill: "embed")
      expect(decision.authorized).to be(false)
      expect(decision.reason).to match(/not granted/)
    end

    it "denies when the target is not online" do
      caller = build_peer(handle: "caller", granted: %w[embed])
      target = build_peer(handle: "target", status: "disconnected", declared_skills: [ { "name" => "embed" } ])

      decision = described_class.authorize(caller_peer: caller, target_peer: target, skill: "embed")
      expect(decision.authorized).to be(false)
      expect(decision.reason).to match(/not enabled\/online/)
    end

    it "denies when the target does not offer the skill" do
      caller = build_peer(handle: "caller", granted: %w[embed])
      target = build_peer(handle: "target", declared_skills: [ { "name" => "summarize" } ])

      decision = described_class.authorize(caller_peer: caller, target_peer: target, skill: "embed")
      expect(decision.authorized).to be(false)
      expect(decision.reason).to match(/does not offer/)
    end

    it "denies cross-account A2A even if every other gate passes" do
      other = create(:account)
      caller = build_peer(handle: "caller", granted: %w[embed])
      target = build_peer(handle: "target", account: other, declared_skills: [ { "name" => "embed" } ])

      decision = described_class.authorize(caller_peer: caller, target_peer: target, skill: "embed")
      expect(decision.authorized).to be(false)
      expect(decision.reason).to match(/cross-account/)
    end
  end
end
