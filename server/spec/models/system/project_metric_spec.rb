# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::ProjectMetric, type: :model do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }
  let(:mission) do
    m = create(
      :ai_mission,
      account: account,
      created_by: user,
      mission_type: "infrastructure",
      custom_phases: [{ "key" => "adapting", "label" => "Adapting", "order" => 0 }]
    )
    m.update_columns(status: "active")
    m
  end

  describe "table mapping" do
    it "maps to system_project_metrics" do
      expect(described_class.table_name).to eq("system_project_metrics")
    end
  end

  describe "associations" do
    it "belongs to an Ai::Mission" do
      metric = create_metric
      expect(metric.mission).to be_a(::Ai::Mission)
      expect(metric.mission_id).to eq(mission.id)
    end

    it "is invalid without a mission" do
      m = described_class.new(metric_name: "p99_latency_ms", metric_type: "latency", value: { "observed" => 100 })
      expect(m).not_to be_valid
      expect(m.errors[:mission]).to be_present
    end
  end

  describe "validations" do
    it "requires metric_name" do
      m = described_class.new(mission: mission, metric_type: "latency", value: { "observed" => 100 })
      expect(m).not_to be_valid
      expect(m.errors[:metric_name]).to be_present
    end

    it "rejects an unknown metric_type" do
      m = described_class.new(mission: mission, metric_name: "p99_latency_ms",
                              metric_type: "speculative", value: { "observed" => 100 })
      expect(m).not_to be_valid
      expect(m.errors[:metric_type]).to be_present
    end

    it "accepts each value in METRIC_TYPES" do
      described_class::METRIC_TYPES.each do |t|
        m = described_class.new(mission: mission, metric_name: "x", metric_type: t,
                                value: { "observed" => 0 })
        expect(m).to be_valid, "expected metric_type=#{t.inspect} to be valid"
      end
    end

    it "defaults sampled_at to now if not supplied" do
      m = described_class.create!(mission: mission, metric_name: "p99_latency_ms",
                                  metric_type: "latency", value: { "observed" => 200 })
      expect(m.sampled_at).to be_within(5.seconds).of(Time.current)
    end
  end

  describe "JSONB value column" do
    it "round-trips a hash payload" do
      m = create_metric(value: { "observed" => 250.5, "target" => 250, "unit" => "ms" })
      expect(m.reload.value).to include("observed" => 250.5, "target" => 250, "unit" => "ms")
    end

    it "exposes #observed and #target convenience accessors" do
      m = create_metric(value: { "observed" => 0.95, "target" => 0.99 })
      expect(m.observed).to eq(0.95)
      expect(m.target).to eq(0.99)
    end

    it "returns nil for #observed when missing" do
      m = create_metric(value: { "note" => "stub" })
      expect(m.observed).to be_nil
    end
  end

  describe ".recent_for_mission" do
    it "returns the latest sample per metric_name for a single mission" do
      now = Time.current
      create_metric(metric_name: "p99_latency_ms", value: { "observed" => 100 },
                    sampled_at: now - 2.minutes)
      latest_latency = create_metric(metric_name: "p99_latency_ms", value: { "observed" => 250 },
                                     sampled_at: now)
      create_metric(metric_name: "cpu_pct", metric_type: "utilization", value: { "observed" => 0.4 },
                    sampled_at: now - 1.minute)
      latest_cpu = create_metric(metric_name: "cpu_pct", metric_type: "utilization",
                                 value: { "observed" => 0.55 }, sampled_at: now)

      rows = described_class.recent_for_mission(mission.id).to_a
      ids = rows.map(&:id)
      expect(ids).to contain_exactly(latest_latency.id, latest_cpu.id)
    end

    it "scopes to the supplied mission only" do
      other_user = create(:user, account: account)
      other_mission = create(
        :ai_mission,
        account: account,
        created_by: other_user,
        mission_type: "infrastructure",
        custom_phases: [{ "key" => "adapting", "label" => "Adapting", "order" => 0 }]
      )
      other_mission.update_columns(status: "active")

      mine = create_metric(metric_name: "p99_latency_ms", value: { "observed" => 100 })
      _theirs = create_metric(mission: other_mission, metric_name: "p99_latency_ms",
                              value: { "observed" => 9_999 })

      rows = described_class.recent_for_mission(mission.id).to_a
      expect(rows.map(&:id)).to eq([ mine.id ])
    end

    it "returns an empty relation when no samples exist for the mission" do
      expect(described_class.recent_for_mission(mission.id).to_a).to eq([])
    end
  end

  def create_metric(mission: self.mission, metric_name: "p99_latency_ms",
                    metric_type: nil, value: { "observed" => 100 }, sampled_at: nil,
                    correlation_id: nil)
    mt = metric_type || System::ProjectMetricsCollector::METRIC_TYPE_MAP.fetch(metric_name, "latency")
    described_class.create!(
      mission: mission,
      metric_name: metric_name,
      metric_type: mt,
      value: value,
      sampled_at: sampled_at || Time.current,
      correlation_id: correlation_id
    )
  end
end
