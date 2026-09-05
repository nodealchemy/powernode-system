# frozen_string_literal: true

require "rails_helper"

# Campaign 01a07025 — WHY a metric has no observation, DECLARED rather than
# inferred from prose.
#
# THE DEFECT. `#unavailable_sample` takes an optional note and falls back to
# "no telemetry backend wired for <metric> yet (TODO metrics-backend)". Five
# samplers pass an explicit note; two did not. So `replica_count` and
# `region_count` — both of which have real, working samplers — announced that
# NO TELEMETRY BACKEND WAS WIRED whenever the mission simply had no resolvable
# instances, which is exactly the condition their five siblings describe
# correctly as "mission has no resolvable instances".
#
# Measured before the fix: three metrics claimed "no telemetry backend wired";
# exactly one of them was actually unwired. One discriminator, two causes,
# lying about two metrics, in operator-facing text.
#
# WHY IT MATTERS BEYOND THE WORDING. The two conditions need OPPOSITE operator
# responses. "No producer" is a capability that does not exist and will not
# appear on its own. "No data" is a temporary gap that fills as soon as the
# mission has instances. Anything that wants to tell a declared-but-
# unmeasurable target from a declared-and-currently-unavailable one has to
# distinguish them, and the note was the only thing carrying that distinction.
#
# THE FIX IS NOT BETTER PROSE. Relying on note text is inferring a
# discriminator from a string that a future edit can reword. The producer now
# DECLARES it: `unavailable_reason` is set by the sampler, defaults to
# no_data, and only the dispatcher's unwired arm passes no_producer. The census
# in spec/lint/project_metric_producer_census_spec.rb is what keeps that arm
# the only unwired path.
RSpec.describe System::ProjectMetricsCollector, "unavailable_reason" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }

  def active_mission
    m = create(:ai_mission, account: account, created_by: user,
                            mission_type: "infrastructure",
                            custom_phases: [ { "key" => "adapting", "label" => "A", "order" => 0 } ],
                            configuration: {})
    m.update_columns(status: "active")
    m
  end

  def rows_for(mission)
    ::System::ProjectMetric.recent_for_mission(mission.id).index_by(&:metric_name)
  end

  # A mission with no resolvable instances: every sampler that needs instances
  # reports unavailable, and NONE of them is unwired.
  let!(:mission) { active_mission }
  before { described_class.collect!(mission: mission) }

  it "stops claiming no telemetry backend for metrics whose sampler exists" do
    rows = rows_for(mission)

    %w[replica_count region_count].each do |metric|
      note = rows.fetch(metric).value["note"].to_s
      expect(note).not_to include("no telemetry backend wired"),
                          "#{metric} has a working sampler; it is unavailable because the mission " \
                          "has no resolvable instances, and saying otherwise sends an operator to " \
                          "debug a subsystem that is fine"
      expect(note).to eq("mission has no resolvable instances")
    end
  end

  it "declares no_producer for exactly the metric that has no sampler" do
    rows = rows_for(mission)
    no_producer = rows.values.select { |r| r.value["unavailable_reason"] == described_class::UNAVAILABLE_NO_PRODUCER }

    expect(no_producer.map(&:metric_name)).to eq([ "p99_latency_ms" ]),
                                              "the no-producer reason must name only the metric nothing measures"
  end

  it "declares no_data for every other unavailable metric" do
    rows = rows_for(mission)
    unavailable = rows.values.select { |r| r.value["source"] == "unavailable" }
    expect(unavailable.size).to be >= 7, "the fixture stopped producing unavailable rows — this would be vacuous"

    no_data = unavailable.reject { |r| r.metric_name == "p99_latency_ms" }
    expect(no_data.map { |r| r.value["unavailable_reason"] }.uniq)
      .to eq([ described_class::UNAVAILABLE_NO_DATA ])
  end

  it "distinguishes the two reasons — they are never the same token" do
    # The equality oracle. Collapsing the two is the defect; this is the
    # assertion that a collapse cannot pass.
    expect(described_class::UNAVAILABLE_NO_PRODUCER).not_to eq(described_class::UNAVAILABLE_NO_DATA)

    rows = rows_for(mission)
    reasons = rows.values.select { |r| r.value["source"] == "unavailable" }
                  .group_by { |r| r.value["unavailable_reason"] }
    expect(reasons.keys.sort).to eq([ described_class::UNAVAILABLE_NO_DATA,
                                      described_class::UNAVAILABLE_NO_PRODUCER ].sort),
                                "both reasons must actually occur, or this fixture proves nothing"
  end

  it "stamps no unavailable_reason on a LIVE sample" do
    platform = create(:system_node_platform, account: account)
    template = create(:system_node_template, account: account, node_platform: platform)
    node     = create(:system_node, account: account, node_template: template)
    inst     = create(:system_node_instance, :running, node: node)
    inst.update!(last_heartbeat_at: 5.seconds.ago)

    other = active_mission
    allow_any_instance_of(described_class).to receive(:resolvable_instance_ids).and_return([ inst.id ])
    described_class.collect!(mission: other)

    live = rows_for(other).values.select { |r| r.value["source"] == "live" }
    expect(live).not_to be_empty
    expect(live.map { |r| r.value["unavailable_reason"] }.uniq).to eq([ nil ]),
                                                                   "a measured sample has no reason to be unavailable"
  end
end
