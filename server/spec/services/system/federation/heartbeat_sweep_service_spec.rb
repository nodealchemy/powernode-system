# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Federation::HeartbeatSweepService, type: :service do
  let(:account) { create(:account) }

  describe ".run!" do
    it "marks active platform peers as degraded when last_heartbeat_at is stale" do
      stale = create(:system_federation_peer, :active,
                     account: account, last_heartbeat_at: 10.minutes.ago)
      result = described_class.run!
      expect(result.swept).to eq(1)
      expect(result.degraded_ids).to include(stale.id)
      expect(stale.reload.status).to eq("degraded")
    end

    it "does not touch active peers with a fresh heartbeat" do
      fresh = create(:system_federation_peer, :active,
                     account: account, last_heartbeat_at: 30.seconds.ago)
      result = described_class.run!
      expect(result.swept).to eq(0)
      expect(fresh.reload.status).to eq("active")
    end

    it "does not touch sdwan_only peers regardless of heartbeat" do
      sdwan = create(:system_federation_peer,
                     account: account, status: "accepted", last_heartbeat_at: nil)
      described_class.run!
      expect(sdwan.reload.status).to eq("accepted")
    end

    it "marks active peers with no heartbeat ever as degraded" do
      never = create(:system_federation_peer, :platform,
                     account: account, status: "active", last_heartbeat_at: nil)
      result = described_class.run!
      expect(result.swept).to eq(1)
      expect(never.reload.status).to eq("degraded")
    end

    it "leaves degraded peers untouched (no auto-suspend)" do
      already_degraded = create(:system_federation_peer, :platform,
                                 account: account, status: "degraded",
                                 last_heartbeat_at: 1.hour.ago)
      described_class.run!
      expect(already_degraded.reload.status).to eq("degraded")
    end

    it "honors a custom threshold" do
      borderline = create(:system_federation_peer, :active,
                          account: account, last_heartbeat_at: 2.minutes.ago)
      # Default threshold is 5m; with a tight 1m threshold, this peer is stale.
      result = described_class.run!(threshold: 1.minute)
      expect(result.swept).to eq(1)
      expect(borderline.reload.status).to eq("degraded")
    end

    it "records the result with ran_at timestamp" do
      result = described_class.run!
      expect(result.ran_at).to be_within(2.seconds).of(Time.current)
    end
  end
end
