# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Metrics::Aggregator do
  # Test isolation — clear the cache between examples so counters from
  # one spec don't leak into another. Production behavior relies on TTL
  # which doesn't fire in test (MemoryStore).
  before do
    Rails.cache.clear if Rails.cache.respond_to?(:clear)
  end

  let(:account_id) { SecureRandom.uuid }
  let(:fixed_now) { Time.utc(2026, 5, 3, 12, 0, 0) }

  describe ".record" do
    it "increments the counter for the current minute bucket" do
      described_class.record(metric_name: "system.dispatch.completed",
                             account_id: account_id, at: fixed_now)
      stats = described_class.stats(metric_name: "system.dispatch.completed",
                                    account_id: account_id, at: fixed_now)
      expect(stats[:count]).to eq(1)
    end

    it "supports multi-increment via value:" do
      described_class.record(metric_name: "system.fleet.event",
                             account_id: account_id, value: 7, at: fixed_now)
      stats = described_class.stats(metric_name: "system.fleet.event",
                                    account_id: account_id, at: fixed_now)
      expect(stats[:count]).to eq(7)
    end

    it "is account-scoped (no cross-tenant leak)" do
      other_account = SecureRandom.uuid
      described_class.record(metric_name: "system.dispatch.completed",
                             account_id: account_id, at: fixed_now)

      stats = described_class.stats(metric_name: "system.dispatch.completed",
                                    account_id: other_account, at: fixed_now)
      expect(stats[:count]).to eq(0)
    end

    it "tolerates blank metric_name without raising" do
      expect {
        described_class.record(metric_name: "", account_id: account_id, at: fixed_now)
      }.not_to raise_error
    end

    it "stores nil-account metrics under the _system namespace" do
      described_class.record(metric_name: "system.cloud_sync.tick", at: fixed_now)
      stats = described_class.stats(metric_name: "system.cloud_sync.tick", at: fixed_now)
      expect(stats[:count]).to eq(1)
    end
  end

  describe ".stats" do
    it "sums counters across the requested window" do
      # 3 records at minute 0, 2 at minute 1, 1 at minute 2 — within a 5min window
      described_class.record(metric_name: "m", account_id: account_id, at: fixed_now)
      described_class.record(metric_name: "m", account_id: account_id, at: fixed_now)
      described_class.record(metric_name: "m", account_id: account_id, at: fixed_now)
      described_class.record(metric_name: "m", account_id: account_id, at: fixed_now + 60)
      described_class.record(metric_name: "m", account_id: account_id, at: fixed_now + 60)
      described_class.record(metric_name: "m", account_id: account_id, at: fixed_now + 120)

      stats = described_class.stats(metric_name: "m", account_id: account_id,
                                    at: fixed_now + 120, window: 5.minutes)

      expect(stats[:count]).to eq(6)
      expect(stats[:window_seconds]).to eq(300)
      expect(stats[:rate_per_sec]).to be_within(0.001).of(6.0 / 300)
    end

    it "returns one bucket entry per minute in the window" do
      stats = described_class.stats(metric_name: "m", account_id: account_id,
                                    at: fixed_now, window: 5.minutes)

      expect(stats[:buckets].size).to eq(5)
      expect(stats[:buckets].all? { |b| b.key?(:ts) && b.key?(:count) }).to be true
    end

    it "ignores records outside the window" do
      described_class.record(metric_name: "m", account_id: account_id, at: fixed_now - 10.minutes)
      described_class.record(metric_name: "m", account_id: account_id, at: fixed_now)

      stats = described_class.stats(metric_name: "m", account_id: account_id,
                                    at: fixed_now, window: 5.minutes)
      expect(stats[:count]).to eq(1)
    end

    it "caps window at MAX_WINDOW (1 hour)" do
      stats = described_class.stats(metric_name: "m", account_id: account_id,
                                    at: fixed_now, window: 24.hours)
      expect(stats[:window_seconds]).to eq(described_class::MAX_WINDOW.to_i)
    end

    it "returns zero count + zero rate for an unknown metric" do
      stats = described_class.stats(metric_name: "never.recorded",
                                    account_id: account_id, at: fixed_now)
      expect(stats[:count]).to eq(0)
      expect(stats[:rate_per_sec]).to eq(0.0)
    end
  end

  describe ".stats_for_names" do
    it "aggregates multiple metric names into a single response" do
      described_class.record(metric_name: "system.dispatch.completed",
                             account_id: account_id, at: fixed_now)
      described_class.record(metric_name: "system.dispatch.failed",
                             account_id: account_id, at: fixed_now)
      described_class.record(metric_name: "system.dispatch.failed",
                             account_id: account_id, at: fixed_now)

      result = described_class.stats_for_names(
        %w[system.dispatch.completed system.dispatch.failed system.dispatch.claimed],
        account_id: account_id, at: fixed_now
      )

      expect(result["system.dispatch.completed"][:count]).to eq(1)
      expect(result["system.dispatch.failed"][:count]).to eq(2)
      expect(result["system.dispatch.claimed"][:count]).to eq(0)
    end
  end

  describe ".reset!" do
    it "wipes recorded buckets for the metric+account scope" do
      described_class.record(metric_name: "m", account_id: account_id, at: fixed_now)
      expect(described_class.stats(metric_name: "m", account_id: account_id,
                                   at: fixed_now)[:count]).to eq(1)

      described_class.reset!(metric_name: "m", account_id: account_id, at: fixed_now)
      expect(described_class.stats(metric_name: "m", account_id: account_id,
                                   at: fixed_now)[:count]).to eq(0)
    end
  end
end
