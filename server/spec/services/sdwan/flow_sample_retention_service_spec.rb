# frozen_string_literal: true

require "rails_helper"

# IMP-b24afe85a309 — system_sdwan_flow_samples is the highest-volume table in
# the extension (per-flow telemetry from every collector-attached node) and had
# no retention path of any kind: nothing deleted, pruned, partitioned or aged
# out those rows. It grew for the life of the install, and every future DDL or
# index build on it got proportionally slower.
#
# The operator direction for this sweep is specific, and each clause is pinned
# below:
#
#   * window DB-driven, no hardcoded retention
#   * deletes batched and bounded, so the first run on a huge table cannot
#     lock ingest
#
# The safety invariant that is NOT in the direction but falls out of the data
# model: the only consumer of this table is
# System::Fleet::Sensors::SdwanServiceHealthSensor, which correlates flows
# inside a DB-driven window of its own. Retention that cuts inside that window
# would delete the rows the sensor is about to read, and the sensor's
# traffic-absent branch would then report every service as silent — turning a
# cleanup job into a false-alarm generator. So the retention floor is derived
# from the sensor's own window rather than being an independent constant.
RSpec.describe Sdwan::FlowSampleRetentionService do
  let(:account) { create(:account) }
  let(:collector) { create(:sdwan_ipfix_collector, account: account) }

  def sample_at(time, acct: account)
    create(:sdwan_flow_sample,
           account: acct,
           ipfix_collector: acct == account ? collector : create(:sdwan_ipfix_collector, account: acct),
           observed_at: time, flow_start_at: time, flow_end_at: time)
  end

  describe "the retention window" do
    it "deletes samples older than the default window and keeps newer ones" do
      old = sample_at(30.days.ago)
      fresh = sample_at(1.hour.ago)

      described_class.call

      expect(Sdwan::FlowSample.exists?(old.id)).to be false
      expect(Sdwan::FlowSample.exists?(fresh.id)).to be true
    end

    it "is DB-driven through SiteSetting rather than hardcoded" do
      # 30 days old: inside the 90-day window this sets, so it must SURVIVE
      # even though the built-in default would have deleted it.
      old = sample_at(30.days.ago)
      SiteSetting.set("#{described_class::SETTING_PREFIX}.retention_seconds", 90.days.to_i.to_s)

      described_class.call

      expect(Sdwan::FlowSample.exists?(old.id)).to be true
    end

    it "lets a per-account setting override the deployment-wide one" do
      sample = sample_at(30.days.ago)
      SiteSetting.set("#{described_class::SETTING_PREFIX}.retention_seconds", 90.days.to_i.to_s)
      account.update!(settings: (account.settings || {}).merge(
        "#{described_class::ACCOUNT_SETTING_PREFIX}_retention_seconds" => 1.day.to_i.to_s
      ))

      described_class.call

      # The account's shorter window wins over the deployment's longer one.
      expect(Sdwan::FlowSample.exists?(sample.id)).to be false
    end
  end

  describe "the sensor-window safety floor" do
    # The failure this prevents: an operator sets retention to a few minutes to
    # reclaim space, the sweep deletes inside the correlation window, and the
    # service-health sensor starts alarming that every service is silent.
    it "refuses to cut inside the window its only consumer reads" do
      SiteSetting.set("#{described_class::SETTING_PREFIX}.retention_seconds", "60")
      recent = sample_at(10.minutes.ago)

      result = described_class.call

      expect(Sdwan::FlowSample.exists?(recent.id)).to be true
      expect(result[:floored]).to be true
    end

    it "derives the floor from the sensor's own window, not a private copy" do
      sensor_window = System::Fleet::Sensors::SdwanServiceHealthSensor
                        .new(account: account).flow_window_seconds

      expect(described_class.retention_floor_seconds(account))
        .to be >= sensor_window
    end
  end

  describe "bounded, batched deletion" do
    it "stops at the per-run cap and reports that it was capped" do
      3.times { sample_at(30.days.ago) }
      SiteSetting.set("#{described_class::SETTING_PREFIX}.max_rows_per_run", "2")

      result = described_class.call

      expect(result[:capped]).to be true
      expect(result[:deleted_total]).to eq(2)
      expect(Sdwan::FlowSample.count).to eq(1)
    end

    it "deletes across multiple bounded batches rather than one unbounded statement" do
      5.times { sample_at(30.days.ago) }
      SiteSetting.set("#{described_class::SETTING_PREFIX}.batch_size", "2")

      result = described_class.call

      expect(result[:deleted_total]).to eq(5)
      expect(result[:batches]).to be > 1
      expect(Sdwan::FlowSample.count).to eq(0)
    end
  end

  describe "account scoping" do
    it "resolves each account's window independently" do
      other = create(:account)
      mine = sample_at(30.days.ago)
      theirs = sample_at(30.days.ago, acct: other)

      other.update!(settings: (other.settings || {}).merge(
        "#{described_class::ACCOUNT_SETTING_PREFIX}_retention_seconds" => 90.days.to_i.to_s
      ))

      described_class.call

      expect(Sdwan::FlowSample.exists?(mine.id)).to be false
      expect(Sdwan::FlowSample.exists?(theirs.id)).to be true
    end
  end
end
