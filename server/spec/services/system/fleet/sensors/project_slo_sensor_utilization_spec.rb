# frozen_string_literal: true

require "rails_helper"

# IMP-7684d3f8658a — cpu_pct / memory_pct are SAMPLED by
# System::ProjectMetricsCollector (APO-2a) but were never READ by this sensor:
# #sample_from_db mapped availability/latency/cost/replica/region/throughput
# and nothing else, and no utilization target was declared anywhere. A
# CPU-bound or memory-bound project therefore never tripped a scale-out signal
# no matter how hot it ran.
#
# The targets themselves live in the mission bounds home (Ai::Mission,
# APO-3a) so the sensor and any other reader cannot disagree about a project's
# declared ceiling.
RSpec.describe System::Fleet::Sensors::ProjectSloSensor, "utilization targets" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:sensor) { described_class.new(account: account) }

  # These ceilings are DECLARED-ONLY (Ai::Mission::DEFAULT_MAX_CPU_PCT is nil):
  # shipping a default would have opened an unattended scale-out path on every
  # project built from the seeded system_provisioning template, which already
  # carries an auto_scale_max_replicas window. So the operator act that turns
  # the check on is modelled explicitly here — the fleet-wide SiteSetting rung
  # — rather than assumed. The "nothing declared" case is its own example
  # below.
  let(:declared_ceiling) { 85.0 }

  before do
    SiteSetting.set(::Ai::Mission::MAX_CPU_PCT_SETTING, declared_ceiling.to_s)
    SiteSetting.set(::Ai::Mission::MAX_MEMORY_PCT_SETTING, declared_ceiling.to_s)
  end

  def build_mission(slo_targets: {}, observations: {})
    mission = create(
      :ai_mission,
      account: account,
      created_by: user,
      mission_type: "infrastructure",
      custom_phases: [ { "key" => "adapting", "label" => "Adapting", "order" => 0 } ],
      configuration: {
        "brief" => {
          "scale" => { "initial" => 3 },
          "regions" => %w[us-east-1]
        },
        "slo_targets" => { "availability_pct" => 99.5, "p99_latency_ms" => 250 }.merge(slo_targets),
        "latest_observations" => observations
      }
    )
    mission.update_columns(status: "active")
    mission
  end

  def write_metric(mission, metric_name, observed:, sampled_at: Time.current)
    metric_type = ::System::ProjectMetricsCollector::METRIC_TYPE_MAP.fetch(metric_name)
    ::System::ProjectMetric.create!(
      mission: mission, metric_name: metric_name, metric_type: metric_type,
      value: { "observed" => observed }, sampled_at: sampled_at
    )
  end

  def violations
    sensor.sense.select { |s| s.kind == "system.project_slo_violation" }
  end

  describe "cpu_pct" do
    # THE RED CASE. 95% busy against the fleet-wide declared ceiling.
    it "fires a slo_violation when the collector's cpu_pct exceeds the target" do
      mission = build_mission
      write_metric(mission, "cpu_pct", observed: 95.0)

      slo = violations.first
      expect(slo).not_to be_nil
      expect(slo.payload["metric"]).to eq("cpu_pct")
      expect(slo.payload["observed"]).to eq(95.0)
      expect(slo.payload["target"]).to eq(declared_ceiling)
      expect(slo.payload["breach_pct"]).to be > 0
      expect(slo.fingerprint).to eq("project_slo_violation:#{mission.id}:cpu_pct")
    end

    # THE SHIPPED DEFAULT. Same 95% reading, no ceiling declared anywhere:
    # silent. This is the example that would have to be deleted for anyone to
    # re-introduce a defaulted ceiling, which is the point — see
    # Ai::Mission::DEFAULT_MAX_CPU_PCT for why that is a money decision.
    it "stays silent at 95% when NO ceiling is declared anywhere" do
      SiteSetting.where(key: [ ::Ai::Mission::MAX_CPU_PCT_SETTING,
                               ::Ai::Mission::MAX_MEMORY_PCT_SETTING ]).delete_all
      mission = build_mission
      write_metric(mission, "cpu_pct", observed: 95.0)

      expect(violations).to be_empty
    end

    # The scale-out consumer sizes from the live fleet — the payload must
    # carry it, exactly as the latency/availability arms do.
    it "carries replica_count on the utilization breach" do
      mission = build_mission
      write_metric(mission, "cpu_pct", observed: 95.0)
      write_metric(mission, "replica_count", observed: 2)

      expect(violations.first.payload["replica_count"]).to eq(2)
    end

    it "honours a project-declared ceiling over the fleet-wide setting" do
      mission = build_mission(slo_targets: { "max_cpu_pct" => 99.0 })
      write_metric(mission, "cpu_pct", observed: 95.0)

      expect(violations).to be_empty
    end

    it "stays silent at or below the target" do
      mission = build_mission(slo_targets: { "max_cpu_pct" => 95.0 })
      write_metric(mission, "cpu_pct", observed: 95.0)

      expect(violations).to be_empty
    end

    # An `unavailable` sample (observed nil) is not a reading. Stated as its
    # own example rather than as a null-vs-zero mutation oracle, because on a
    # CEILING it is not one: a fabricated 0.0 sits below every positive target
    # too, so both spellings stay silent here. What this pins is the outcome
    # that matters — a mission the collector could not measure must not be
    # signalled about — with the DB arm kept live by a second row so the
    # example cannot pass merely by falling through to the config seam.
    it "does NOT fire for an unavailable cpu sample" do
      mission = build_mission
      write_metric(mission, "cpu_pct", observed: nil)
      write_metric(mission, "replica_count", observed: 3)

      expect(violations).to be_empty
    end

    it "yields to a latency breach — the first violated metric wins" do
      mission = build_mission
      write_metric(mission, "p99_latency_ms", observed: 900.0)
      write_metric(mission, "cpu_pct", observed: 99.0)

      expect(violations.first.payload["metric"]).to eq("p99_latency_ms")
    end

    it "also reads cpu_pct from the config observation seam" do
      build_mission(observations: { "cpu_pct" => 97.0 })

      slo = violations.first
      expect(slo).not_to be_nil
      expect(slo.payload["metric"]).to eq("cpu_pct")
      expect(slo.payload["observed"]).to eq(97.0)
    end
  end

  # -------------------------------------------------------------------
  # The DB-vs-config precedence this change widened. #sample_observations
  # picks the DB arm whenever the MAPPED hash carries any non-nil value, and
  # that hash gained cpu_pct/memory_pct — so a mission whose only real rows
  # are utilization ones now reads from the DB instead of falling through to
  # the synthetic `latest_observations` blob. Intended (the config seam is
  # for a mission with no metrics history, and this one has one), but it is a
  # behaviour change and it is pinned here rather than left to be rediscovered.
  # -------------------------------------------------------------------
  describe "DB-vs-config precedence" do
    it "prefers real utilization rows over a stale config observation blob" do
      mission = build_mission(observations: { "p99_latency_ms" => 5000.0 })
      write_metric(mission, "cpu_pct", observed: 95.0)

      metrics = violations.map { |s| s.payload["metric"] }
      expect(metrics).to include("cpu_pct")
      expect(metrics).not_to include("p99_latency_ms")
    end

    it "still falls through to the config blob when NO metric row is readable" do
      mission = build_mission(observations: { "p99_latency_ms" => 5000.0 })
      write_metric(mission, "cpu_pct", observed: nil)

      expect(violations.first.payload["metric"]).to eq("p99_latency_ms")
    end
  end

  describe "memory_pct" do
    it "fires a slo_violation when the collector's memory_pct exceeds the target" do
      mission = build_mission
      write_metric(mission, "memory_pct", observed: 97.5)

      slo = violations.first
      expect(slo).not_to be_nil
      expect(slo.payload["metric"]).to eq("memory_pct")
      expect(slo.payload["observed"]).to eq(97.5)
      expect(slo.payload["target"]).to eq(declared_ceiling)
      expect(slo.fingerprint).to eq("project_slo_violation:#{mission.id}:memory_pct")
    end

    it "does NOT fire for an unavailable memory sample" do
      mission = build_mission
      write_metric(mission, "memory_pct", observed: nil)
      write_metric(mission, "replica_count", observed: 3)

      expect(violations).to be_empty
    end

    it "yields to a cpu breach when both are over target" do
      mission = build_mission
      write_metric(mission, "cpu_pct", observed: 99.0)
      write_metric(mission, "memory_pct", observed: 99.0)

      expect(violations.first.payload["metric"]).to eq("cpu_pct")
    end
  end
end
