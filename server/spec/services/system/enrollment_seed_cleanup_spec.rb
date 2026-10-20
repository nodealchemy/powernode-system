# frozen_string_literal: true

require "rails_helper"

# IMP-02a42b90598b (Provisioning D13): best-effort seed cleanup after enrolment.
# Single use is the real control; this only narrows the window in which an
# already-spent key's carrier stays readable. It must never raise into, or roll
# back, the enrolment, never force a restart, and never log key material.
RSpec.describe System::EnrollmentSeedCleanup do
  let(:instance) { create(:system_node_instance) }
  let(:seeded) { true }
  let(:adapter) { double("provider adapter", provider_type: "gcp") }

  before do
    instance.merge_config!("cloud_instance_id" => "cloud-id-1")
    System::EnrollmentSeed.issue_token(instance: instance) if seeded
    allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter)
  end

  def state
    instance.reload.config.dig("seed_cleanup", "state")
  end

  def cleanup_audits
    AuditLog.where(action: "system.enrollment_seed.cleanup", resource_id: instance.id)
  end

  describe ".mark_pending!" do
    it "marks a platform-seeded instance pending" do
      described_class.mark_pending!(instance)
      expect(state).to eq("pending")
    end

    context "when the platform never seeded the instance" do
      let(:seeded) { false }

      it "leaves it alone (its user-data is not ours)" do
        described_class.mark_pending!(instance)
        expect(instance.reload.config).not_to have_key("seed_cleanup")
      end
    end

    it "never raises" do
      allow(instance).to receive(:merge_config!).and_raise(StandardError, "db down")
      expect { described_class.mark_pending!(instance) }.not_to raise_error
    end
  end

  describe ".run!" do
    before { described_class.mark_pending!(instance) }

    it "records a cleared outcome with an audit row and stops retrying" do
      expect(adapter).to receive(:clear_enrollment_seed!).with("cloud-id-1", instance: instance)
                                                         .and_return(outcome: :cleared, note: "removed user-data")
      described_class.run!(instance)

      expect(state).to eq("done")
      audit = cleanup_audits.last
      expect(audit.metadata).to include("outcome" => "cleared", "provider_type" => "gcp")
    end

    it "records a no-op with the provider's audit note (AWS / OpenStack)" do
      allow(adapter).to receive(:provider_type).and_return("aws")
      allow(adapter).to receive(:clear_enrollment_seed!)
        .and_return(outcome: :noop, note: "aws user-data is only changeable while stopped")
      described_class.run!(instance)

      expect(state).to eq("done")
      expect(cleanup_audits.last.metadata).to include("outcome" => "noop", "note" => /only changeable while stopped/)
    end

    it "keeps waiting (backed off, one audit row) while the seed is only queued for the next stop" do
      allow(adapter).to receive(:clear_enrollment_seed!).and_return(outcome: :awaiting_stop, note: "queued")
      2.times { described_class.run!(instance) }

      expect(state).to eq("awaiting_stop")
      expect(Time.iso8601(instance.reload.config.dig("seed_cleanup", "next_attempt_at"))).to be > 5.minutes.from_now
      expect(cleanup_audits.where("metadata->>'outcome' = 'awaiting_stop'").count).to eq(1)
    end

    it "swallows a provider failure, backs off, and counts the attempt" do
      allow(adapter).to receive(:clear_enrollment_seed!).and_raise(StandardError, "provider 500")
      expect { described_class.run!(instance) }.not_to raise_error

      cfg = instance.reload.config["seed_cleanup"]
      expect(cfg).to include("state" => "pending", "attempts" => 1)
      expect(Time.iso8601(cfg["next_attempt_at"])).to be > Time.current
    end

    it "gives up (failed, audited) after the attempt cap" do
      allow(adapter).to receive(:clear_enrollment_seed!).and_raise(StandardError, "provider 500")
      described_class::MAX_ATTEMPTS.times { described_class.run!(instance) }

      expect(state).to eq("failed")
      expect(cleanup_audits.last.metadata).to include("outcome" => "failed")
    end

    it "counts a missing provider connection as a failed attempt, not an exception" do
      allow(System::Providers::Registry).to receive(:for_instance)
        .and_raise(System::Providers::Registry::UnknownProviderError, "no connection")
      expect { described_class.run!(instance) }.not_to raise_error
      expect(instance.reload.config.dig("seed_cleanup", "attempts")).to eq(1)
    end

    it "never writes key material into the audit row or the logs" do
      key = "not-a-real-enrol-key-123"
      allow(adapter).to receive(:clear_enrollment_seed!).and_raise(StandardError, "boom #{key}")
      io = StringIO.new
      sink = Logger.new(io)
      Rails.logger.broadcast_to(sink)
      described_class.run!(instance)
      Rails.logger.stop_broadcasting_to(sink)

      expect(io.string).not_to include(key)
      expect(instance.reload.config.to_json).not_to include(key)
    end

    it "does nothing for an instance that is not pending" do
      instance.merge_config!("seed_cleanup" => { "state" => "done" })
      expect(adapter).not_to receive(:clear_enrollment_seed!)
      described_class.run!(instance)
    end
  end

  describe ".sweep!" do
    before do
      allow(adapter).to receive(:clear_enrollment_seed!).and_return(outcome: :cleared, note: "ok")
    end

    it "runs due pending instances of the account, and skips ones backed off into the future" do
      described_class.mark_pending!(instance)
      waiting = create(:system_node_instance, account: instance.account)
      waiting.merge_config!("seed_cleanup" => { "state" => "awaiting_stop", "next_attempt_at" => 1.hour.from_now.utc.iso8601 })

      expect(described_class.sweep!(account: instance.account)).to eq(1)
      expect(state).to eq("done")
      expect(waiting.reload.config.dig("seed_cleanup", "state")).to eq("awaiting_stop")
    end

    it "does not touch another account's instances" do
      other = create(:system_node_instance)
      other.merge_config!("seed_cleanup" => { "state" => "pending" })
      expect(described_class.sweep!(account: instance.account)).to eq(0)
      expect(other.reload.config.dig("seed_cleanup", "state")).to eq("pending")
    end

    it "honours the batch limit" do
      described_class.mark_pending!(instance)
      expect(described_class.sweep!(account: instance.account, limit: 0)).to eq(0)
    end

    it "never raises" do
      described_class.mark_pending!(instance)
      allow(described_class).to receive(:run!).and_raise(StandardError, "x")
      expect { described_class.sweep!(account: instance.account) }.not_to raise_error
    end
  end
end
