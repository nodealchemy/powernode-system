# frozen_string_literal: true

require "rails_helper"

# Self-improvement Phase 0 — the validate step: record PROCEEDED remediations,
# then score them against a later sense pass (fingerprint cleared => effective).
RSpec.describe System::Fleet::RemediationValidator, type: :service do
  let(:account) { create(:account) }
  let(:validator) { described_class.new(account: account) }

  def sig(fingerprint, kind: "system.cert_expiring", payload: { "instance_id" => "i-1" })
    System::Fleet::Signal.new(kind: kind, severity: :high, payload: payload, fingerprint: fingerprint)
  end

  def proceeded(fingerprint, kind: "system.cert_expiring")
    { decision: :proceed, gate: "notify_and_proceed", signal_kind: kind,
      fingerprint: fingerprint, action_category: "system.cert_rotate" }
  end

  describe "#record_proceeded!" do
    it "records one pending outcome per PROCEEDED decision (not pending/blocked), keyed by fingerprint" do
      signals = [sig("fp-1"), sig("fp-2")]
      decisions = [proceeded("fp-1"), { decision: :pending, signal_kind: "x", fingerprint: "fp-2" }]

      expect { validator.record_proceeded!(decisions: decisions, signals: signals) }
        .to change { System::Fleet::RemediationOutcome.pending.count }.by(1)

      o = System::Fleet::RemediationOutcome.pending.last
      expect(o.fingerprint).to eq("fp-1")
      expect(o.signal_kind).to eq("system.cert_expiring")
      expect(o.action_category).to eq("system.cert_rotate")
      expect(o.resource_ref).to eq("i-1")
      expect(o.settle_until).to be > o.acted_at
    end

    it "does not duplicate a pending outcome for the same fingerprint (same unresolved problem)" do
      validator.record_proceeded!(decisions: [proceeded("fp-1")], signals: [sig("fp-1")])
      expect { validator.record_proceeded!(decisions: [proceeded("fp-1")], signals: [sig("fp-1")]) }
        .not_to change { System::Fleet::RemediationOutcome.pending.count }
    end
  end

  describe "#validate_due!" do
    let!(:outcome) do
      System::Fleet::RemediationOutcome.create!(
        account: account, signal_kind: "system.cert_expiring", fingerprint: "fp-1",
        status: "pending", acted_at: 5.minutes.ago, settle_until: 4.minutes.ago
      )
    end

    it "marks EFFECTIVE when the fingerprint cleared from the live signals" do
      result = validator.validate_due!(current_signals: [sig("fp-OTHER")])
      expect(result[:effective]).to eq(1)
      expect(outcome.reload.status).to eq("effective")
      expect(outcome.effectiveness_score).to eq(1.0)
      expect(outcome.validated_at).to be_present
    end

    it "marks INEFFECTIVE when the fingerprint still fires (remediation didn't stick)" do
      result = validator.validate_due!(current_signals: [sig("fp-1")])
      expect(result[:ineffective]).to eq(1)
      expect(outcome.reload.status).to eq("ineffective")
      expect(outcome.effectiveness_score).to eq(0.0)
    end

    it "ignores outcomes whose settle window has not elapsed" do
      outcome.update!(settle_until: 5.minutes.from_now)
      validator.validate_due!(current_signals: [])
      expect(outcome.reload.status).to eq("pending")
    end
  end
end
