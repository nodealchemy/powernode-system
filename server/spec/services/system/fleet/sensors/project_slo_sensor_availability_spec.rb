# frozen_string_literal: true

require "rails_helper"

# Campaign 01a07025 increment app-5 — ABSENT IS NOT ZERO on the availability
# FLOOR.
#
# WHY THIS FILE EXISTS, stated precisely so nobody reads it as a bug fix it is
# not. ProjectSloSensor's availability arm behaves correctly today. What it did
# not have was a single test: every one of the twelve existing examples in
# project_slo_sensor_spec.rb passes `availability_pct` as 99.9 background
# scenery to keep the latency and drift arms clean, and not one asserts that
# the availability arm fires at all. The producer half IS pinned —
# project_metrics_collector_spec.rb has "publishes a measured 0.0 when every
# reporting replica has gone silent" alongside five unavailable-is-nil examples
# — so the collector is proven to publish the distinction and nothing was
# proven to ACT on it. That asymmetry is the shape worth closing: the
# definition is pinned, the consumer is not.
#
# THE PROPERTY. A measured 0.0 and an unmeasured nil must produce DIFFERENT
# observable outcomes:
#
#   measured 0.0  → every replica that owes us a heartbeat has gone silent.
#                   That is a total outage and the most severe thing this
#                   sensor can say. It MUST fire.
#   unmeasured    → the collector could not measure availability at all (no
#                   resolvable instances, nothing ever enrolled, nothing in a
#                   state where a heartbeat is expected). It MUST NOT fire —
#                   rendering "we cannot see it" as 0% manufactures an outage
#                   that is not happening.
#
# Both directions are wrong in a way the other cannot catch, which is why each
# has its own example and each is mutation-checked separately.
#
# WHY AVAILABILITY AND NOT CPU. On a CEILING (cpu_pct, memory_pct) an
# unmeasured nil and a fabricated 0.0 both sit below every positive threshold,
# so the distinction is unobservable in the signal and the collector says so in
# its own comment. That is survivable: not knowing looks like being comfortably
# under the limit. A FLOOR inverts it — not knowing looks like total failure —
# and availability and the SDWAN throughput floor are the two floors this
# sensor has. The throughput floor already spells its guard `!observed.nil?`
# and its comment warns that a later reader "tidying" it into a truthiness test
# would swallow the measured zero. The availability floor directly above it was
# the truthiness test that comment describes.
RSpec.describe System::Fleet::Sensors::ProjectSloSensor, "the availability floor" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }
  let(:sensor)  { described_class.new(account: account) }

  def build_mission(slo_targets: { "availability_pct" => 99.5, "p99_latency_ms" => 250 })
    mission = create(
      :ai_mission,
      account: account,
      created_by: user,
      mission_type: "infrastructure",
      custom_phases: [ { "key" => "adapting", "label" => "Adapting", "order" => 0 } ],
      configuration: { "slo_targets" => slo_targets }
    )
    mission.update_columns(status: "active")
    mission
  end

  # Writes the row the collector writes. `observed: nil` is the collector's
  # honest unavailable sample — see ProjectMetricsCollector#unavailable_sample,
  # which records nil plus a note and never a zero.
  def write_metric(mission, metric_name, observed:)
    ::System::ProjectMetric.create!(
      mission: mission, metric_name: metric_name,
      metric_type: ::System::ProjectMetricsCollector::METRIC_TYPE_MAP.fetch(metric_name),
      value: { "observed" => observed }, sampled_at: Time.current
    )
  end

  def availability_signal
    sensor.sense.find do |s|
      s.kind == "system.project_slo_violation" && s.payload["metric"] == "availability_pct"
    end
  end

  it "fires on a MEASURED 0.0 — every replica that owes a heartbeat has gone silent" do
    mission = build_mission
    write_metric(mission, "availability_pct", observed: 0.0)

    signal = availability_signal
    expect(signal).not_to be_nil,
                          "a measured 0.0 is a total outage, the most severe thing this sensor says"
    expect(signal.payload["observed"]).to eq(0.0)
    expect(signal.payload["target"]).to eq(99.5)
    expect(signal.severity).to eq(:critical)
    expect(signal.fingerprint).to eq("project_slo_violation:#{mission.id}:availability_pct")
  end

  it "stays SILENT on an unmeasured availability — absence is not an outage" do
    mission = build_mission
    # Exactly what the collector writes when it cannot measure: observed nil.
    write_metric(mission, "availability_pct", observed: nil)
    # A second, real metric so the sensor's DB arm is actually taken rather
    # than falling through to the legacy config seam on an all-nil batch.
    write_metric(mission, "replica_count", observed: 3)

    expect(availability_signal).to be_nil,
                                   "rendering 'we cannot see it' as 0% manufactures an outage"
  end

  it "still fires for an ordinary partial outage between the two extremes" do
    mission = build_mission
    write_metric(mission, "availability_pct", observed: 50.0)

    signal = availability_signal
    expect(signal).not_to be_nil
    expect(signal.payload["observed"]).to eq(50.0)
    expect(signal.payload["breach_pct"]).to be > 0
  end

  it "stays silent when availability is at or above target" do
    mission = build_mission
    write_metric(mission, "availability_pct", observed: 99.9)

    expect(availability_signal).to be_nil
  end

  # The two halves must be distinguishable BY THE SIGNAL, not merely by the
  # sample. This is the equality oracle: collapse measured-zero and unmeasured
  # into one outcome and the pair below can no longer both hold.
  it "gives a measured zero and an unmeasured absence DIFFERENT outcomes" do
    measured   = build_mission
    unmeasured = build_mission
    write_metric(measured, "availability_pct", observed: 0.0)
    write_metric(unmeasured, "availability_pct", observed: nil)
    write_metric(unmeasured, "replica_count", observed: 3)

    fired = sensor.sense.select do |s|
      s.kind == "system.project_slo_violation" && s.payload["metric"] == "availability_pct"
    end

    expect(fired.map { |s| s.payload["mission_id"] }).to eq([ measured.id ])
  end
end
