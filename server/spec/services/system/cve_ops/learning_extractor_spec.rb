# frozen_string_literal: true

require "rails_helper"

# IMP: fleet/CVE reconcile-tick learnings mass-produced near-duplicates —
# the CVE extractor lacked Fleet's F3-12 title-fingerprint upsert, so every
# 60s tick created a fresh row (and the generic near-dup boost path drove
# importance toward ~0.87 with injection_count 0).
RSpec.describe System::CveOps::LearningExtractor do
  let(:account) { create(:account) }

  let(:embedding_service) { instance_double(Ai::Memory::EmbeddingService, generate: nil) }

  before do
    allow(Ai::Memory::EmbeddingService).to receive(:new).and_return(embedding_service)
  end

  let(:decisions) do
    [
      {
        signal_kind: "system.cve_published",
        action_category: "system.cve_triage",
        gate: "notify_and_proceed",
        decision: :proceed,
        skill_result: { success: true, data: { cve_id: "CVE-2026-0001", triage: { risk_score: 8.1 } } }
      }
    ]
  end

  describe ".record_tick! upsert-by-fingerprint dedupe" do
    it "creates the pattern row once, then reinforces it on subsequent ticks" do
      expect {
        described_class.record_tick!(account: account, decisions: decisions)
      }.to change { Ai::CompoundLearning.where(account: account).count }.by(1)

      row = Ai::CompoundLearning.where(account: account).order(:created_at).last
      expect(row.title).to eq("CVE system.cve_published → notify_and_proceed")

      expect {
        described_class.record_tick!(account: account, decisions: decisions)
        described_class.record_tick!(account: account, decisions: decisions)
      }.not_to change { Ai::CompoundLearning.where(account: account).count }

      row.reload
      expect(row.access_count).to eq(2)
    end

    it "keeps importance flat across reinforcement ticks (no 0.03/tick drift)" do
      described_class.record_tick!(account: account, decisions: decisions)
      row = Ai::CompoundLearning.where(account: account).order(:created_at).last
      seeded = row.importance_score.to_f

      described_class.record_tick!(account: account, decisions: decisions)

      expect(row.reload.importance_score.to_f).to eq(seeded)
    end
  end

  describe "calibrated importance" do
    it "seeds discovery-category rows at the calibrated 0.35, not the 0.5 tool default" do
      described_class.record_tick!(account: account, decisions: decisions)

      row = Ai::CompoundLearning.where(account: account).order(:created_at).last
      expect(row.category).to eq("discovery")
      expect(row.importance_score.to_f).to eq(0.35)
    end

    it "seeds pattern-category (pending-decision) rows at the calibrated 0.45" do
      pending_decisions = [ decisions.first.merge(decision: :pending, gate: "approval_required") ]

      described_class.record_tick!(account: account, decisions: pending_decisions)

      row = Ai::CompoundLearning.where(account: account).order(:created_at).last
      expect(row.category).to eq("pattern")
      expect(row.importance_score.to_f).to eq(0.45)
    end
  end
end
