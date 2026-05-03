# frozen_string_literal: true

require "rails_helper"

# Comprehensive stabilization sweep P6 — verifies atomic concurrency
# behavior on System::NodeInstancePeer. The model carries two operations
# (reserve_decision!, record_execution!) that must remain correct under
# concurrent access; this spec is the contract.
RSpec.describe System::NodeInstancePeer, type: :model do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, node: node) }
  let(:peer) do
    described_class.create!(
      account: account,
      node_instance: instance,
      handle: "instance-#{SecureRandom.hex(4)}",
      enabled: true,
      status: "active",
      trust_score: 0.5,
      daily_decision_budget: 5,
      daily_decision_used: 0,
      first_announced_at: 1.hour.ago,
      last_announced_at: 1.hour.ago
    )
  end

  describe "#reserve_decision!" do
    it "increments the counter and returns true within budget" do
      result = peer.reserve_decision!
      expect(result).to be true
      expect(peer.reload.daily_decision_used).to eq(1)
    end

    it "returns false (without incrementing) when budget exhausted" do
      peer.update!(daily_decision_used: 5, daily_decision_window_start: Time.current)

      result = peer.reserve_decision!
      expect(result).to be false
      expect(peer.reload.daily_decision_used).to eq(5)
    end

    it "rolls over the window when stale (>24h)" do
      peer.update!(daily_decision_used: 5, daily_decision_window_start: 25.hours.ago)

      result = peer.reserve_decision!
      expect(result).to be true
      peer.reload
      expect(peer.daily_decision_used).to eq(1)
      expect(peer.daily_decision_window_start).to be_within(5.seconds).of(Time.current)
    end

    it "initializes the window on first call" do
      peer.update!(daily_decision_window_start: nil)

      peer.reserve_decision!

      peer.reload
      expect(peer.daily_decision_window_start).to be_within(5.seconds).of(Time.current)
      expect(peer.daily_decision_used).to eq(1)
    end

    it "allows decisions up to (but not exceeding) the budget" do
      4.times { expect(peer.reserve_decision!).to be true }
      expect(peer.reload.daily_decision_used).to eq(4)

      expect(peer.reserve_decision!).to be true # 5th — at the limit
      expect(peer.reload.daily_decision_used).to eq(5)

      expect(peer.reserve_decision!).to be false # 6th — over the limit
      expect(peer.reload.daily_decision_used).to eq(5)
    end
  end

  describe "#record_execution!" do
    it "increments execution_count + advances last_executed_at on success" do
      peer.record_execution!(success: true)
      peer.reload
      expect(peer.execution_count).to eq(1)
      expect(peer.execution_failure_count).to eq(0)
      expect(peer.last_executed_at).to be_within(2.seconds).of(Time.current)
    end

    it "increments both counters on failure" do
      peer.record_execution!(success: false)
      peer.reload
      expect(peer.execution_count).to eq(1)
      expect(peer.execution_failure_count).to eq(1)
    end

    it "bumps trust_score by +0.005 on success" do
      peer.update!(trust_score: 0.5)

      peer.record_execution!(success: true)

      expect(peer.reload.trust_score.to_f).to be_within(0.0001).of(0.505)
    end

    it "drops trust_score by -0.02 on failure" do
      peer.update!(trust_score: 0.5)

      peer.record_execution!(success: false)

      expect(peer.reload.trust_score.to_f).to be_within(0.0001).of(0.48)
    end

    it "clamps trust_score at 1.0 ceiling" do
      peer.update!(trust_score: 1.0)

      peer.record_execution!(success: true)

      expect(peer.reload.trust_score.to_f).to eq(1.0)
    end

    it "clamps trust_score at 0.0 floor" do
      peer.update!(trust_score: 0.005)

      peer.record_execution!(success: false)

      expect(peer.reload.trust_score.to_f).to eq(0.0)
    end
  end

  describe "validations" do
    it "requires unique handle within an account" do
      handle = "instance-dupe"
      described_class.create!(
        account: account, node_instance: instance, handle: handle,
        first_announced_at: Time.current, last_announced_at: Time.current
      )

      other_instance = create(:system_node_instance, node: node)
      duplicate = described_class.new(
        account: account, node_instance: other_instance, handle: handle,
        first_announced_at: Time.current, last_announced_at: Time.current
      )

      expect(duplicate.valid?).to be false
      expect(duplicate.errors[:handle]).to be_present
    end

    it "rejects trust_score outside [0, 1]" do
      peer.trust_score = 1.5
      expect(peer.valid?).to be false

      peer.trust_score = -0.1
      expect(peer.valid?).to be false

      peer.trust_score = 0.5
      expect(peer.valid?).to be true
    end

    it "rejects negative daily_decision_budget" do
      peer.daily_decision_budget = -1
      expect(peer.valid?).to be false
    end
  end

  describe "scopes" do
    let!(:enabled_peer) { peer }
    let!(:disabled_peer) do
      described_class.create!(
        account: account,
        node_instance: create(:system_node_instance, node: node),
        handle: "instance-disabled-#{SecureRandom.hex(2)}",
        enabled: false, status: "registered",
        first_announced_at: Time.current, last_announced_at: Time.current
      )
    end

    it ".enabled returns only activated peers" do
      result = described_class.enabled.pluck(:id)
      expect(result).to include(enabled_peer.id)
      expect(result).not_to include(disabled_peer.id)
    end

    it ".active returns only status=active peers" do
      result = described_class.active.pluck(:id)
      expect(result).to include(enabled_peer.id)
      expect(result).not_to include(disabled_peer.id)
    end
  end
end
