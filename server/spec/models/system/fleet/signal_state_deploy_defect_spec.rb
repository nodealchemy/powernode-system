# frozen_string_literal: true

require "rails_helper"
require_relative "../../../support/schema_defect_helpers"

# Every write on this model rescues StandardError and falls back to the
# behaviour that predates the table. That is right for a transient failure
# and wrong for a table that is not there: on the CI checkout the table was
# stamped-as-applied but never created, and the standing-signal lane spent
# weeks reporting a healthy tick over a no-op. A schema defect now RE-RAISES
# from every write arm; a runtime failure keeps its documented fallback.
RSpec.describe System::Fleet::SignalState, "deploy-defect discipline" do
  let(:account) { create(:account) }
  let(:signal) do
    System::Fleet::Signal.new(kind: "system.cert_expiring", severity: :medium,
                              payload: {}, fingerprint: "cert_expiring:defect")
  end

  def failing_upsert(error)
    allow(described_class).to receive(:upsert_locked).and_raise(error)
  end

  describe ".record_dedupe!" do
    it "re-raises when the table is missing" do
      failing_upsert(schema_defect_error)

      expect { described_class.record_dedupe!(account: account, signal: signal) }
        .to raise_error(ActiveRecord::StatementInvalid, /does not exist/)
    end

    it "still returns nil on a transient write failure" do
      failing_upsert(transient_statement_error)

      expect(described_class.record_dedupe!(account: account, signal: signal)).to be_nil
    end
  end

  describe ".claim_notification!" do
    it "re-raises when the table is missing" do
      failing_upsert(schema_defect_error)

      expect {
        described_class.claim_notification!(account: account, fingerprint: "f", signal_kind: "k")
      }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "still fails OPEN (claims) on a transient write failure" do
      failing_upsert(transient_statement_error)

      expect(described_class.claim_notification!(account: account, fingerprint: "f", signal_kind: "k")).to be(true)
    end
  end

  describe "the instance stamps" do
    let!(:state) { described_class.record_dedupe!(account: account, signal: signal) }

    before { expect(state).to be_a(described_class) }

    it "record_escalation! re-raises a schema defect and returns false on a transient one" do
      allow(state).to receive(:update_columns).and_raise(schema_defect_error)
      expect { state.record_escalation! }.to raise_error(ActiveRecord::StatementInvalid)

      allow(state).to receive(:update_columns).and_raise(transient_statement_error)
      expect(state.record_escalation!).to be(false)
    end

    it "record_decision! re-raises a schema defect and returns false on a transient one" do
      allow(state).to receive(:update_columns).and_raise(schema_defect_error)
      expect { state.record_decision!("deduped") }.to raise_error(ActiveRecord::StatementInvalid)

      allow(state).to receive(:update_columns).and_raise(transient_statement_error)
      expect(state.record_decision!("deduped")).to be(false)
    end

    it "claim_dedup_event! re-raises a schema defect and fails open on a transient one" do
      allow(state).to receive(:update_columns).and_raise(schema_defect_error)
      expect { state.claim_dedup_event! }.to raise_error(ActiveRecord::StatementInvalid)

      allow(state).to receive(:update_columns).and_raise(transient_statement_error)
      expect(state.claim_dedup_event!).to be(true)
    end
  end
end
