# frozen_string_literal: true

require "rails_helper"
require_relative "../../support/project_metric_samplers"

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

  # ── THE DERIVED CENSUS ─────────────────────────────────────────────────────
  #
  # DERIVED FROM THE DISPATCH, never a hardcoded list. A list is a place for a
  # third omission to be added, and adding it is how the defect this spec
  # closes came to cover two metrics instead of one. ProjectMetricSamplers
  # reads `#sample_one`'s case statement, so the truth about which metrics have
  # samplers comes from the code that dispatches to them; a metric that stops
  # being dispatched joins the unproduced set here without anybody editing this
  # file, and a metric that omits its note reddens rather than joining.
  #
  # Both directions matter. A sampler-less metric that does NOT get the default
  # note is also wrong — it would be claiming a temporary gap for a capability
  # that does not exist.
  it "gives the no-telemetry-backend note to EXACTLY the metrics with no sampler" do
    unproduced = ProjectMetricSamplers.unproduced
    expect(unproduced).not_to be_empty,
      "every metric has a sampler, so this oracle proves nothing — delete it or fix the scan"

    rows = rows_for(mission)
    defaulted = rows.values
                    .select { |r| r.value["note"].to_s.include?("no telemetry backend wired") }
                    .map(&:metric_name).sort

    expect(defaulted).to eq(unproduced), <<~MSG
      The collector's default note claims NO TELEMETRY BACKEND IS WIRED. It must reach
      exactly the metrics #sample_one dispatches to no sampler.

        metrics with no sampler:   #{unproduced.inspect}
        metrics given the default: #{defaulted.inspect}

      A metric in the second list but not the first has a WORKING sampler and is
      telling an operator to go debug a subsystem that is fine — that is the defect
      this spec was written for, arriving through a third call site. Pass that
      sampler's real reason as the note argument to #unavailable_sample.
    MSG
  end

  # The same set, through the DECLARED token rather than the prose. The two
  # must agree: the token is what code reads and the note is what a person
  # reads, and a lane that fires on one while an operator reads the other is
  # the discriminator problem again with an extra step.
  it "declares no_producer for exactly the metrics with no sampler" do
    unproduced = ProjectMetricSamplers.unproduced
    rows = rows_for(mission)
    no_producer = rows.values
                      .select { |r| r.value["unavailable_reason"] == described_class::UNAVAILABLE_NO_PRODUCER }
                      .map(&:metric_name).sort

    expect(no_producer).to eq(unproduced),
      "the no_producer token and the no-telemetry-backend note must name the same metrics; " \
      "code reads the token, an operator reads the note, and they cannot disagree"
  end

  it "declares no_data for every other unavailable metric" do
    rows = rows_for(mission)
    unavailable = rows.values.select { |r| r.value["source"] == "unavailable" }
    expect(unavailable.size).to be >= 7, "the fixture stopped producing unavailable rows — this would be vacuous"

    no_data = unavailable.reject { |r| ProjectMetricSamplers.unproduced.include?(r.metric_name) }
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
