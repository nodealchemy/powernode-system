# frozen_string_literal: true

require "rails_helper"

# Campaign 01a07025 — the SENSOR half of the target-bypass fix.
#
# THE DEFECT. Ai::Mission resolves a project's declarations through one ladder,
# and the PROJECT rung was wired into it for the scaling window and the two
# utilization ceilings. The other three service-level targets never went
# through that ladder at all: this sensor read availability, the cost ceiling
# and the throughput floor straight off `mission.configuration["slo_targets"]`.
# So a project could declare an availability target, the write would land in a
# row, and nothing on the evaluation path would ever look at it. The
# declaration was silently unobserved.
#
# WHY THESE EXAMPLES AND NOT THE CORE ONES. The core lane's specs assert that
# Ai::Mission#service_level_targets returns the right number. Every one of them
# would still pass with this sensor reading around the ladder, because they
# never run the sensor. The oracle for a BYPASS has to be the emitted SIGNAL:
# declare a target on the PROJECT ONLY, leave the mission's own targets empty,
# run the sense pass, and assert the signal was evaluated against the project's
# figure. That is the assertion the bypass fails and only that assertion.
RSpec.describe System::Fleet::Sensors::ProjectSloSensor, "declared service-level targets" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }
  let(:sensor)  { described_class.new(account: account) }

  def build_mission(mission_slo: {}, project_slo: nil, brief: nil)
    project = if project_slo
      create(:ai_project, account: account,
                          configuration: { "slo_targets" => project_slo })
    end

    cfg = { "slo_targets" => mission_slo }
    cfg["brief"] = brief if brief

    mission = create(:ai_mission, account: account, created_by: user,
                                  mission_type: "infrastructure",
                                  custom_phases: [ { "key" => "adapting", "label" => "A", "order" => 0 } ],
                                  configuration: cfg)
    mission.update_columns(status: "active", ai_project_id: project&.id)
    mission
  end

  def write_metric(mission, metric_name, observed:)
    ::System::ProjectMetric.create!(
      mission: mission, metric_name: metric_name,
      metric_type: ::System::ProjectMetricsCollector::METRIC_TYPE_MAP.fetch(metric_name),
      value: { "observed" => observed }, sampled_at: Time.current
    )
  end

  def signal_for(metric)
    sensor.sense.find { |s| s.payload["metric"] == metric }
  end

  # The cost breach is its OWN signal kind and carries `target_usd` rather than
  # the `metric`/`target` pair the slo_violation payload uses — a shape
  # difference that silently made an earlier draft of these examples look like
  # a code failure when it was a spec failure.
  def cost_signal
    sensor.sense.find { |s| s.kind == "system.project_cost_breach" }
  end

  # ── THE ORACLE ────────────────────────────────────────────────────────────

  it "evaluates availability against a target the PROJECT declared and the mission did not" do
    mission = build_mission(mission_slo: {}, project_slo: { "availability_pct" => 99.99 })
    # Inside the shipped 99.5 default, OUTSIDE the project's stricter 99.99.
    # A sensor still reading the mission's own configuration resolves the
    # default, sees no breach, and emits nothing.
    write_metric(mission, "availability_pct", observed: 99.7)

    signal = signal_for("availability_pct")
    expect(signal).not_to be_nil,
                          "the project's declaration was not observed — the sensor read around the ladder"
    expect(signal.payload["target"]).to eq(99.99)
    expect(signal.payload["observed"]).to eq(99.7)
  end

  it "evaluates a throughput floor the PROJECT declared and the mission did not" do
    mission = build_mission(mission_slo: {}, project_slo: { "min_throughput_bytes_per_s" => 1_000 })
    write_metric(mission, "sdwan_throughput_bytes_per_s", observed: 10.0)

    signal = signal_for("sdwan_throughput_bytes_per_s")
    expect(signal).not_to be_nil
    expect(signal.payload["target"]).to eq(1_000.0)
  end

  it "lets a PROJECT cost ceiling outrank the brief's budget cap" do
    # The brief's budget_cap_usd_monthly is a REQUIRED brief field, so every
    # completed provisioning brief carries one. It used to be read here as the
    # only fallback, ABOVE any project declaration — which is exactly why a
    # project-declared ceiling could never be observed on a provisioning
    # mission. The ladder now places it BELOW the project rung.
    mission = build_mission(mission_slo: {},
                            project_slo: { "cost_ceiling_usd" => 50.0 },
                            brief: { "budget_cap_usd_monthly" => 5_000.0 })
    write_metric(mission, "cost_usd_mtd", observed: 100.0)

    signal = cost_signal
    expect(signal).not_to be_nil,
                          "the brief's cap shadowed the project's ceiling — the defect this closes"
    expect(signal.payload["target_usd"]).to eq(50.0)
  end

  it "still honours the brief's budget cap for a mission with NO project" do
    # The regression direction: a mission with no project must resolve byte for
    # byte as it did before the ladder gained the rung.
    mission = build_mission(mission_slo: {}, brief: { "budget_cap_usd_monthly" => 80.0 })
    write_metric(mission, "cost_usd_mtd", observed: 100.0)

    signal = cost_signal
    expect(signal).not_to be_nil
    expect(signal.payload["target_usd"]).to eq(80.0)
  end

  it "lets the MISSION's own declaration outrank the project's" do
    mission = build_mission(mission_slo: { "availability_pct" => 99.0 },
                            project_slo: { "availability_pct" => 99.99 })
    write_metric(mission, "availability_pct", observed: 99.5)

    # 99.5 is under the project's 99.99 but over the mission's own 99.0, and
    # the mission is the more specific object, so nothing fires.
    expect(signal_for("availability_pct")).to be_nil
  end

  # ── BEHAVIOUR CHANGES ON DEPLOY, asserted rather than discovered ──────────

  it "reads an out-of-range availability declaration as NOT DECLARED, not verbatim" do
    # BEHAVIOUR CHANGE. `150` used to become the target verbatim, and no
    # observation can ever be under it, so the metric was silently unchecked
    # while looking declared. It now resolves to not-declared and the sensor
    # falls back to its own default, which DOES check.
    mission = build_mission(mission_slo: { "availability_pct" => 150 })
    write_metric(mission, "availability_pct", observed: 99.0)

    signal = signal_for("availability_pct")
    expect(signal).not_to be_nil
    expect(signal.payload["target"]).to eq(described_class::DEFAULT_AVAILABILITY_PCT)
  end

  it "reads a ZERO availability declaration as NOT DECLARED, not as a floor of nothing" do
    # BEHAVIOUR CHANGE, and the louder of the two. A declared 0 used to survive
    # `0.0 || DEFAULT` — zero is truthy in Ruby — so the target became 0.0 and
    # the arm could never fire. Such a mission now evaluates against the
    # default and starts reporting real breaches.
    mission = build_mission(mission_slo: { "availability_pct" => 0 })
    write_metric(mission, "availability_pct", observed: 50.0)

    signal = signal_for("availability_pct")
    expect(signal).not_to be_nil
    expect(signal.payload["target"]).to eq(described_class::DEFAULT_AVAILABILITY_PCT)
  end

  it "does not fall through to the brief's cap when the mission's OWN cost ceiling is unusable" do
    # BEHAVIOUR CHANGE, and the one that makes the deleted fallback matter.
    # The reader stops at the FIRST rung that speaks: an unusable declaration
    # resolves to not-declared and does NOT continue to a wider rung, because a
    # target inherited from somewhere broader is a claim nobody made about this
    # project. Keeping the brief fallback beside the reader would silently
    # reinstate exactly that inheritance — the "two answers" this change removes
    # — and it is the ONLY input on which the duplicate is observable, which is
    # why an oracle without this example cannot see it.
    mission = build_mission(mission_slo: { "cost_ceiling_usd" => -5 },
                            brief: { "budget_cap_usd_monthly" => 80.0 })
    write_metric(mission, "cost_usd_mtd", observed: 100.0)

    expect(cost_signal).to be_nil,
                           "an unusable declaration inherited the brief's cap instead of resolving to not-declared"
  end

  it "leaves a non-positive throughput floor UNCHECKED, exactly as before" do
    # NOT a behaviour change, despite looking like one. The floor branch has
    # always guarded `floor.positive?`, so a declared 0 was already unchecked;
    # the only difference is that the target arrives as nil instead of 0.0,
    # which no signal can observe. Pinned as an INVARIANCE so nobody records it
    # as a deploy-time change it is not.
    mission = build_mission(mission_slo: { "min_throughput_bytes_per_s" => 0 })
    write_metric(mission, "sdwan_throughput_bytes_per_s", observed: 0.0)

    expect(signal_for("sdwan_throughput_bytes_per_s")).to be_nil
  end

  # ── The latency target is untouched ───────────────────────────────────────

  it "leaves the dormant latency target on its own path" do
    # The reader deliberately resolves nothing for latency, so wiring it here
    # would silently drop the target to nil. Changing the dormant default is a
    # separate decision and is not part of this.
    mission = build_mission(mission_slo: { "p99_latency_ms" => 100 })
    write_metric(mission, "p99_latency_ms", observed: 500.0)

    signal = signal_for("p99_latency_ms")
    expect(signal).not_to be_nil
    expect(signal.payload["target"]).to eq(100.0)
  end

  # ── The absent-vs-zero property, re-checked through the NEW path ──────────

  it "still tells a measured 0.0 availability from an unmeasured one" do
    # The floor guard was written against the old target path. Resolution now
    # ends at not-declared, which is a NEW way for a value to arrive absent, so
    # the property is re-asserted here rather than assumed to have survived.
    measured   = build_mission(mission_slo: {}, project_slo: { "availability_pct" => 99.5 })
    unmeasured = build_mission(mission_slo: {}, project_slo: { "availability_pct" => 99.5 })
    write_metric(measured, "availability_pct", observed: 0.0)
    write_metric(unmeasured, "availability_pct", observed: nil)
    write_metric(unmeasured, "replica_count", observed: 3)

    fired = sensor.sense.select { |s| s.payload["metric"] == "availability_pct" }
    expect(fired.map { |s| s.payload["mission_id"] }).to eq([ measured.id ])
  end
end
