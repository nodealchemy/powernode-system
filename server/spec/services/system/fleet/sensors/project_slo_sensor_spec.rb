# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Fleet::Sensors::ProjectSloSensor do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:sensor) { described_class.new(account: account) }

  # Build an active infrastructure mission with a brief + slo_targets +
  # synthetic latest_observations (the sensor's M0/M1 sanity path).
  def build_mission(observations: {}, slo_targets: nil, brief: nil)
    cfg = {}
    cfg["brief"] = brief || {
      "intent" => "Spin up a 3-region web stack",
      "use_case" => "Side business",
      "scale" => { "initial" => 3, "target" => 5 },
      "regions" => %w[us-east-1 us-west-2 eu-west-1],
      "budget_cap_usd_monthly" => 200.0,
      "latency_targets_ms" => { "p99" => 250 }
    }
    cfg["slo_targets"] = slo_targets || {
      "availability_pct" => 99.5,
      "p99_latency_ms" => 250,
      "cost_ceiling_usd" => 200.0
    }
    cfg["latest_observations"] = observations

    mission = create(
      :ai_mission,
      account: account,
      created_by: user,
      mission_type: "infrastructure",
      custom_phases: [{ "key" => "adapting", "label" => "Adapting", "order" => 0 }],
      configuration: cfg
    )
    mission.update_columns(status: "active")
    mission
  end

  describe "#sense" do
    it "emits no signals when observations are within target" do
      build_mission(observations: {
        "p99_latency_ms" => 200,
        "availability_pct" => 99.9,
        "month_to_date_cost_usd" => 150.0,
        "actual_replica_count" => 3,
        "actual_region_count" => 3
      })

      expect(sensor.sense).to be_empty
    end

    it "emits a system.project_slo_violation when p99 latency exceeds target" do
      mission = build_mission(observations: {
        "p99_latency_ms" => 500,
        "availability_pct" => 99.9,
        "actual_replica_count" => 3,
        "actual_region_count" => 3
      })

      signals = sensor.sense
      slo = signals.find { |s| s.kind == "system.project_slo_violation" }
      expect(slo).not_to be_nil
      expect(slo.payload).to include(
        "mission_id" => mission.id,
        "metric" => "p99_latency_ms",
        "observed" => 500.0,
        "target" => 250.0
      )
      expect(slo.payload["breach_pct"]).to be > 0
      expect(slo.payload["correlation_id"]).to start_with("project_slo:#{mission.id}:")
      expect(slo.fingerprint).to eq("project_slo_violation:#{mission.id}:p99_latency_ms")
    end

    it "scales severity with breach percentage" do
      build_mission(observations: {
        "p99_latency_ms" => 1000, # 300% over → critical
        "availability_pct" => 99.9
      })
      slo = sensor.sense.find { |s| s.kind == "system.project_slo_violation" }
      expect(slo.severity).to eq(:critical)
    end

    it "emits a project_drift signal when actual_replica_count differs from expected" do
      mission = build_mission(observations: {
        "p99_latency_ms" => 200,
        "availability_pct" => 99.9,
        "actual_replica_count" => 1, # expected 3
        "actual_region_count" => 3
      })

      drift = sensor.sense.find { |s| s.kind == "system.project_drift" }
      expect(drift).not_to be_nil
      expect(drift.payload).to include(
        "mission_id" => mission.id,
        "drift_type" => "replica_count",
        "observed" => 1,
        "target" => 3
      )
      expect(drift.payload["correlation_id"]).to start_with("project_slo:#{mission.id}:")
    end

    it "emits a project_drift signal when actual_region_count differs from expected" do
      build_mission(observations: {
        "p99_latency_ms" => 200,
        "availability_pct" => 99.9,
        "actual_replica_count" => 3,
        "actual_region_count" => 1 # expected 3
      })

      drift = sensor.sense.find { |s| s.kind == "system.project_drift" }
      expect(drift).not_to be_nil
      expect(drift.payload["drift_type"]).to eq("region_count")
    end

    it "emits a project_cost_breach signal when month-to-date cost exceeds the ceiling" do
      mission = build_mission(observations: {
        "p99_latency_ms" => 200,
        "availability_pct" => 99.9,
        "month_to_date_cost_usd" => 280.0
      })

      cost = sensor.sense.find { |s| s.kind == "system.project_cost_breach" }
      expect(cost).not_to be_nil
      expect(cost.payload).to include(
        "mission_id" => mission.id,
        "observed_usd" => 280.0,
        "target_usd" => 200.0
      )
      expect(cost.payload["breach_pct"]).to be > 0
    end

    it "skips cost breach when no ceiling is configured" do
      build_mission(
        observations: { "month_to_date_cost_usd" => 1000.0 },
        slo_targets: { "availability_pct" => 99.5, "p99_latency_ms" => 250 },
        brief: { "scale" => { "initial" => 1 }, "regions" => %w[us-east-1], "budget_cap_usd_monthly" => nil }
      )

      cost_signals = sensor.sense.select { |s| s.kind == "system.project_cost_breach" }
      expect(cost_signals).to be_empty
    end

    it "scopes to the current account" do
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      other_mission = create(
        :ai_mission,
        account: other_account,
        created_by: other_user,
        mission_type: "infrastructure",
        custom_phases: [{ "key" => "adapting", "label" => "Adapting", "order" => 0 }],
        configuration: {
          "brief" => { "scale" => { "initial" => 3 }, "regions" => %w[us-east-1] },
          "slo_targets" => { "p99_latency_ms" => 250 },
          "latest_observations" => { "p99_latency_ms" => 5000 }
        }
      )
      other_mission.update_columns(status: "active")

      expect(sensor.sense).to be_empty
    end

    it "ignores draft / completed missions" do
      mission = build_mission(observations: { "p99_latency_ms" => 5000 })
      mission.update_columns(status: "completed")

      expect(sensor.sense).to be_empty
    end

    it "ignores non-infrastructure missions" do
      mission = build_mission(observations: { "p99_latency_ms" => 5000 })
      mission.update_columns(mission_type: "operations")

      expect(sensor.sense).to be_empty
    end

    it "returns an empty array (not nil) when there is nothing to evaluate" do
      expect(sensor.sense).to eq([])
    end

    it "does not crash when configuration is missing" do
      mission = create(
        :ai_mission,
        account: account,
        created_by: user,
        mission_type: "infrastructure",
        custom_phases: [{ "key" => "adapting", "label" => "Adapting", "order" => 0 }],
        configuration: {}
      )
      mission.update_columns(status: "active")

      expect { sensor.sense }.not_to raise_error
    end
  end

  describe "signal correlation_id format" do
    it "buckets correlation_ids per mission per minute" do
      mission = build_mission(observations: { "p99_latency_ms" => 1000 })
      signals = sensor.sense
      slo = signals.find { |s| s.kind == "system.project_slo_violation" }
      expect(slo.payload["correlation_id"]).to match(/\Aproject_slo:#{mission.id}:\d+\z/)
    end
  end

  # The sensor prefers DB-backed metrics (System::ProjectMetric) over the
  # legacy mission.configuration["latest_observations"] test seam. When the
  # collector has populated rows for a mission, those drive the signals;
  # the config-blob fallback only kicks in for missions without persisted
  # samples (or when all DB samples are stub zeros — e.g. before a real
  # metrics backend lands).
  describe "DB-backed metrics path" do
    def write_metric(mission, metric_name, observed:, sampled_at: Time.current)
      metric_type = ::System::ProjectMetricsCollector::METRIC_TYPE_MAP.fetch(metric_name)
      ::System::ProjectMetric.create!(
        mission: mission, metric_name: metric_name, metric_type: metric_type,
        value: { "observed" => observed }, sampled_at: sampled_at
      )
    end

    it "reads p99_latency_ms from System::ProjectMetric when available" do
      mission = build_mission(observations: {
        "p99_latency_ms" => 100, # would be within target → no signal
        "availability_pct" => 99.9
      })
      # DB sample blows through the target — should override config-blob path.
      write_metric(mission, "p99_latency_ms", observed: 800)

      slo = sensor.sense.find { |s| s.kind == "system.project_slo_violation" }
      expect(slo).not_to be_nil
      expect(slo.payload["observed"]).to eq(800.0)
      expect(slo.payload["target"]).to eq(250.0)
    end

    it "uses the latest sample when multiple exist for the same metric" do
      mission = build_mission(observations: { "p99_latency_ms" => 100 })
      write_metric(mission, "p99_latency_ms", observed: 999, sampled_at: 5.minutes.ago)
      write_metric(mission, "p99_latency_ms", observed: 600, sampled_at: 1.second.ago)

      slo = sensor.sense.find { |s| s.kind == "system.project_slo_violation" }
      expect(slo).not_to be_nil
      expect(slo.payload["observed"]).to eq(600.0)
    end

    it "emits a project_drift signal when DB-backed replica_count differs from expected" do
      mission = build_mission(observations: {
        "p99_latency_ms" => 200, # within target
        "actual_replica_count" => 3 # config matches, but DB will override
      })
      write_metric(mission, "replica_count", observed: 1) # expected 3

      drift = sensor.sense.find { |s| s.kind == "system.project_drift" }
      expect(drift).not_to be_nil
      expect(drift.payload["drift_type"]).to eq("replica_count")
      expect(drift.payload["observed"]).to eq(1)
      expect(drift.payload["target"]).to eq(3)
    end

    it "emits a project_cost_breach when DB-backed cost_usd_mtd exceeds the ceiling" do
      mission = build_mission(observations: { "month_to_date_cost_usd" => 100.0 })
      write_metric(mission, "cost_usd_mtd", observed: 280.0)

      cost = sensor.sense.find { |s| s.kind == "system.project_cost_breach" }
      expect(cost).not_to be_nil
      expect(cost.payload["observed_usd"]).to eq(280.0)
      expect(cost.payload["target_usd"]).to eq(200.0)
    end

    it "falls back to mission.configuration['latest_observations'] when only stub-zero metrics exist" do
      # Collector wrote zero-valued stub metrics (no real telemetry yet).
      # Sensor must NOT use those — drift/violation should come from config blob.
      mission = build_mission(observations: {
        "p99_latency_ms" => 500.0, # config-blob breach
        "availability_pct" => 99.9
      })
      ::System::ProjectMetricsCollector::METRIC_TYPE_MAP.each_key do |name|
        write_metric(mission, name, observed: 0)
      end

      slo = sensor.sense.find { |s| s.kind == "system.project_slo_violation" }
      expect(slo).not_to be_nil
      expect(slo.payload["observed"]).to eq(500.0) # came from config blob
    end

    it "falls back to config blob when no DB metrics exist for the mission" do
      mission = build_mission(observations: {
        "p99_latency_ms" => 500.0,
        "availability_pct" => 99.9
      })

      expect(::System::ProjectMetric.where(mission_id: mission.id).count).to eq(0)

      slo = sensor.sense.find { |s| s.kind == "system.project_slo_violation" }
      expect(slo).not_to be_nil
      expect(slo.payload["observed"]).to eq(500.0)
    end
  end
end
