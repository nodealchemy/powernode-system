# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M8 — LearningExtractor records reconcile-tick decision
# patterns as compound learnings.
RSpec.describe System::Fleet::LearningExtractor do
  let(:account)  { create(:account) }
  let(:agent)    { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:embedding_service) { instance_double(Ai::Memory::EmbeddingService, generate: nil) }

  before do
    allow(Ai::Memory::EmbeddingService).to receive(:new).and_return(embedding_service)
  end

  def tagged_learning!(signal_kind)
    create(:ai_compound_learning, account: account, tags: [ "fleet", "autonomy", signal_kind ])
  end

  let(:decisions) do
    [
      {
        signal_kind: "system.module_drift",
        action_category: "system.module_assign",
        gate: "notify_and_proceed",
        decision: :proceed,
        skill_result: { success: true, data: { disruption_pct: 20 } }
      }
    ]
  end

  describe ".record_tick!" do
    context "with a proceeded decision" do
      it "records the decision pattern as a learning" do
        expect {
          described_class.record_tick!(account: account, decisions: decisions)
        }.to change { Ai::CompoundLearning.where(account: account).count }.by(1)
      end
    end

    context "with empty decisions list" do
      it "is a no-op" do
        expect(Rails.logger).not_to receive(:info)
        described_class.record_tick!(account: account, decisions: [])
      end
    end

    context "with a skipped decision" do
      it "does not record a learning" do
        skipped = [ {
          signal_kind: "system.unknown",
          action_category: nil,
          gate: nil,
          decision: :skipped
        } ]

        expect(Ai::CompoundLearning).not_to receive(:where) if defined?(Ai::CompoundLearning)
        expect {
          described_class.record_tick!(account: account, decisions: skipped)
        }.not_to change(Ai::CompoundLearning, :count) if defined?(Ai::CompoundLearning)
      end
    end

    # Audit F3-12 — :deduped (29,642/day live) and blocked-by-not_permitted
    # buckets generated zero-information learnings every 60s tick: 5,249
    # "Fleet ..." rows were 30% of the entire knowledge base, degrading
    # platform.query_learnings for every agent.
    context "zero-information buckets (F3-12)" do
      it "skips deduped decisions entirely" do
        deduped = [ {
          signal_kind: "system.instance_silent",
          gate: nil,
          decision: :deduped,
          reason: "fingerprint decided within last 300s"
        } ]

        expect(described_class).not_to receive(:submit_learning)
        described_class.record_tick!(account: account, decisions: deduped)
      end

      it "skips blocked buckets whose only reason is not_permitted" do
        blocked = [ {
          signal_kind: "system.unbound_action",
          gate: nil,
          decision: :blocked,
          reason: "not_permitted"
        } ]

        expect(described_class).not_to receive(:submit_learning)
        described_class.record_tick!(account: account, decisions: blocked)
      end

      it "still learns from policy blocks (blocked with a gate)" do
        policy_blocked = [ {
          signal_kind: "system.module_drift",
          action_category: "system.module_assign",
          gate: "block",
          decision: :blocked
        } ]

        expect(described_class).to receive(:submit_learning)
        described_class.record_tick!(account: account, decisions: policy_blocked)
      end
    end

    # The auto-evolve trigger is gone. It called SelfImprovementTool's
    # auto_evolve_skill with no user and no agent, which the tool refuses
    # (permission denied), and it logged only on success, so it never ran.
    # The instance_double that stood in for the tool here is what hid that.
    context "with matching learnings past the old auto-evolve threshold" do
      it "still records learnings and never builds a SelfImprovementTool" do
        3.times { tagged_learning!("system.module_drift") }
        expect(::Ai::Tools::SelfImprovementTool).not_to receive(:new)

        expect {
          described_class.record_tick!(account: account, decisions: decisions)
        }.to change { Ai::CompoundLearning.where(account: account).count }.by(1)
      end
    end
  end

  # Audit F3-12 — one-time cleanup for the rows created before the
  # reinforce/skip logic existed (5,249 live rows, 30% of the KB).
  describe ".consolidate_legacy_rows!" do
    def fleet_learning!(title, created_at: Time.current, access_count: 0)
      create(:ai_compound_learning, account: account, title: title,
             created_at: created_at, access_count: access_count,
             tags: %w[fleet autonomy])
    end

    it "deletes zero-information rows and collapses duplicates onto the oldest" do
      keeper = fleet_learning!("Fleet system.module_drift → notify_and_proceed",
                               created_at: 3.days.ago, access_count: 5)
      fleet_learning!("Fleet system.module_drift → notify_and_proceed", created_at: 2.days.ago)
      fleet_learning!("Fleet system.module_drift → notify_and_proceed", created_at: 1.day.ago)
      fleet_learning!("Fleet system.instance_silent → deduped")
      fleet_learning!("Fleet system.honeypot_access → blocked")
      unique = fleet_learning!("Fleet system.cert_expiring → cert_rotate")
      unrelated = create(:ai_compound_learning, account: account, title: "Unrelated learning")

      result = described_class.consolidate_legacy_rows!

      expect(result[:deleted_zero_info]).to eq(2)
      expect(result[:deleted_duplicates]).to eq(2)
      titles = Ai::CompoundLearning.where(account: account).pluck(:title)
      expect(titles).to contain_exactly(
        "Fleet system.module_drift → notify_and_proceed",
        "Fleet system.cert_expiring → cert_rotate",
        "Unrelated learning"
      )
      expect(keeper.reload.access_count).to eq(7) # 5 + 2 folded duplicates
      expect(Ai::CompoundLearning.exists?(unique.id)).to be true
      expect(Ai::CompoundLearning.exists?(unrelated.id)).to be true
    end
  end
end
