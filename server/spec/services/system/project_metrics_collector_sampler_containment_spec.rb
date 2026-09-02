# frozen_string_literal: true

require "rails_helper"

# IMP-7684d3f8658a — ONE raising sampler used to cost the mission its ENTIRE
# metric batch for the tick.
#
# `sample_all` had no per-metric rescue and `FleetAutonomyService`'s
# collect_project_metrics! only rescues per MISSION, so a raise inside
# sample_cpu_pct / sample_memory_pct / sample_availability_pct /
# sample_replica_count / sample_region_count / sample_cost_usd_mtd propagated
# out of `collect!` and took every OTHER metric — including replica_count, and
# therefore drift detection — dark with it. Only sample_sdwan_throughput
# contained its own failures (it says so in its rescue).
#
# The containment mirrors that sampler: log a warning, record an honest
# `unavailable` sample for the metric that failed, and let the rest of the
# batch land.
RSpec.describe System::ProjectMetricsCollector, "per-metric failure containment" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }

  def build_active_infrastructure_mission
    m = create(
      :ai_mission,
      account: account,
      created_by: user,
      mission_type: "infrastructure",
      custom_phases: [ { "key" => "adapting", "label" => "Adapting", "order" => 0 } ]
    )
    m.update_columns(status: "active")
    m
  end

  # Every wired sampler, not just the one that happened to raise in the field.
  %w[
    sample_cpu_pct
    sample_memory_pct
    sample_availability_pct
    sample_replica_count
    sample_region_count
    sample_cost_usd_mtd
  ].each do |sampler|
    it "keeps the rest of the batch when ##{sampler} raises" do
      mission = build_active_infrastructure_mission
      allow_any_instance_of(described_class)
        .to receive(sampler.to_sym).and_raise(RuntimeError, "boom from #{sampler}")

      expect {
        described_class.collect!(mission: mission)
      }.not_to raise_error

      names = System::ProjectMetric.where(mission_id: mission.id).pluck(:metric_name)
      expect(names).to match_array(described_class::METRIC_TYPE_MAP.keys)
    end
  end

  it "records the failed metric as an honest unavailable sample, never a fabricated zero" do
    mission = build_active_infrastructure_mission
    allow_any_instance_of(described_class)
      .to receive(:sample_cpu_pct).and_raise(RuntimeError, "boom")

    described_class.collect!(mission: mission)

    row = System::ProjectMetric.where(mission_id: mission.id, metric_name: "cpu_pct").first
    expect(row.value).to include("observed" => nil, "source" => "unavailable")
    expect(row.value["note"].to_s).to include("RuntimeError")
  end

  it "does not swallow the failure silently — it is logged" do
    mission = build_active_infrastructure_mission
    allow_any_instance_of(described_class)
      .to receive(:sample_memory_pct).and_raise(RuntimeError, "boom")

    allow(Rails.logger).to receive(:warn)
    expect(Rails.logger).to receive(:warn).with(/memory_pct/).at_least(:once)
    described_class.collect!(mission: mission)
  end
end
