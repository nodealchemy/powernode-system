# frozen_string_literal: true

require "rails_helper"

# Campaign 01a07025 — THE VISIBILITY HALF of the unmeasured-metric increment.
#
# WHAT WAS INVISIBLE. A project can declare `p99_latency_ms` today. The
# declaration lands in a row, resolves through Ai::Mission's ladder, reaches
# this sensor's target hash, and is then compared against nothing forever,
# because nothing on this platform measures workload latency and nothing will
# until somebody builds a prober (IMP-6355c5adc382 ruled the transport DORMANT
# on 2026-08-23; see the block comment at DEFAULT_P99_LATENCY_MS). The operator
# who declared it is told nothing. The target is inert and looks enforced.
#
# THE TWO CONSTRAINTS THIS LANE IS BUILT UNDER, and the examples that hold them:
#
#   1. It must RIDE THE STANDING-SIGNAL MACHINERY rather than emitting per
#      tick. The sensor's contribution to that is a fingerprint that is stable
#      across ticks — that is what lets DecisionEngine#recently_decided? dedupe
#      it and System::Fleet::SignalState age it into ONE escalation. A
#      fingerprint carrying a timestamp, a tick counter or an observation would
#      defeat the whole mechanism and recreate the flood app-2 removed. Pinned
#      by "the fingerprint is stable across sense passes".
#
#   2. It must DISTINGUISH declared-but-unmeasurable from declared-and-
#      currently-unavailable. Those need opposite operator responses: the first
#      is a capability that does not exist (drop the declaration, or fund a
#      producer), the second fills in on its own as soon as the fleet has
#      instances. The discriminator is the `unavailable_reason` token
#      ProjectMetricsCollector now DECLARES on every unavailable sample — never
#      the note prose, which is one reword from meaning nothing. Pinned by the
#      no_data example, which must stay SILENT.
#
# AND THE NO-FLOOD ORACLE. `p99_latency_ms` has a DEFAULT (250ms), so every
# infrastructure mission resolves a latency target whether or not anybody asked
# for one. Firing on a resolved target would page the operator of every mission
# on the fleet on the first tick after deploy. This lane fires only on a target
# somebody DECLARED. Pinned by "a mission that declared nothing stays silent",
# which is the example that fails if a later change reads targets[] instead of
# the declaration.
RSpec.describe System::Fleet::Sensors::ProjectSloSensor, "unmeasurable declared targets" do
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

  # Writes the sample shape ProjectMetricsCollector actually persists, reason
  # token included. `observed: nil` + a reason is the unavailable shape; an
  # observed value with no reason is the live shape.
  def write_metric(mission, metric_name, observed: nil, reason: nil, note: nil)
    value = { "observed" => observed }
    value["source"] = observed.nil? ? "unavailable" : "live"
    value["unavailable_reason"] = reason if reason
    value["note"] = note if note

    ::System::ProjectMetric.create!(
      mission: mission, metric_name: metric_name,
      metric_type: ::System::ProjectMetricsCollector::METRIC_TYPE_MAP.fetch(metric_name),
      value: value, sampled_at: Time.current
    )
  end

  # The kind is read off the SENSOR, not restated here. A literal would keep
  # passing if the constant were renamed and the binding left behind, which is
  # the half of this lane a spec cannot otherwise see. (It is also why this is
  # not a bare constant in the describe block — one defined there lands on
  # Object and can clobber a same-named constant in another spec file.)
  def unmeasurable_signals
    sensor.sense.select { |s| s.kind == described_class::UNMEASURABLE_SIGNAL_KIND }
  end

  # ── THE ORACLE: no_producer fires ─────────────────────────────────────────

  it "reports a declared target whose metric has no producer" do
    mission = build_mission(mission_slo: { "p99_latency_ms" => 100 })
    write_metric(mission, "p99_latency_ms",
                 reason: ::System::ProjectMetricsCollector::UNAVAILABLE_NO_PRODUCER,
                 note: "no telemetry backend wired for p99_latency_ms yet (TODO metrics-backend)")

    signals = unmeasurable_signals
    expect(signals.size).to eq(1),
      "expected exactly one unmeasurable-target signal, got #{signals.map(&:fingerprint).inspect}"

    signal = signals.first
    expect(signal.payload["metric"]).to eq("p99_latency_ms")
    expect(signal.payload["mission_id"]).to eq(mission.id)
    expect(signal.payload["target"]).to eq(100.0)
    expect(signal.payload["unavailable_reason"])
      .to eq(::System::ProjectMetricsCollector::UNAVAILABLE_NO_PRODUCER)
  end

  # ── CONSTRAINT 2: no_data must stay silent ────────────────────────────────

  it "stays silent for a declared target whose metric has a producer and no data" do
    mission = build_mission(mission_slo: { "availability_pct" => 99.9 })
    write_metric(mission, "availability_pct",
                 reason: ::System::ProjectMetricsCollector::UNAVAILABLE_NO_DATA,
                 note: ::System::ProjectMetricsCollector::NO_RESOLVABLE_INSTANCES_NOTE)

    expect(unmeasurable_signals).to be_empty,
      "a metric whose sampler works and had nothing to measure this tick fills in on its own; " \
      "escalating it to an operator is the flood this lane exists to avoid"
  end

  # THE DISCRIMINATING PAIR. The two examples above differ in ONE token. If a
  # later change infers the reason from the note, or drops the reason check and
  # fires on any unavailable sample, this example is what goes red — the pair
  # is the whole point, so assert the difference directly rather than trusting
  # two independent examples to stay opposite.
  it "distinguishes the two absences by the DECLARED token alone" do
    producerless = build_mission(mission_slo: { "availability_pct" => 99.9 })
    write_metric(producerless, "availability_pct",
                 reason: ::System::ProjectMetricsCollector::UNAVAILABLE_NO_PRODUCER,
                 note: ::System::ProjectMetricsCollector::NO_RESOLVABLE_INSTANCES_NOTE)

    # Same metric, same declared target, same NOTE — only the token differs.
    dataless = build_mission(mission_slo: { "availability_pct" => 99.9 })
    write_metric(dataless, "availability_pct",
                 reason: ::System::ProjectMetricsCollector::UNAVAILABLE_NO_DATA,
                 note: ::System::ProjectMetricsCollector::NO_RESOLVABLE_INSTANCES_NOTE)

    reported = unmeasurable_signals.map { |s| s.payload["mission_id"] }
    expect(reported).to eq([ producerless.id ]),
      "the note is identical on both rows; only the reason token separates them"
  end

  # ── THE NO-FLOOD ORACLE ───────────────────────────────────────────────────

  it "stays silent for a mission that declared no target, even with no producer" do
    mission = build_mission(mission_slo: {})
    write_metric(mission, "p99_latency_ms",
                 reason: ::System::ProjectMetricsCollector::UNAVAILABLE_NO_PRODUCER)

    expect(unmeasurable_signals).to be_empty,
      "p99_latency_ms carries a 250ms DEFAULT, so every infrastructure mission resolves a " \
      "latency target; firing on a resolved target pages the whole fleet on the first tick"
  end

  it "stays silent for a declared target that IS measured" do
    mission = build_mission(mission_slo: { "availability_pct" => 99.9 })
    write_metric(mission, "availability_pct", observed: 99.95)

    expect(unmeasurable_signals).to be_empty
  end

  # ── THE LADDER ────────────────────────────────────────────────────────────

  it "sees a target the PROJECT declared and the mission did not" do
    mission = build_mission(mission_slo: {}, project_slo: { "availability_pct" => 99.99 })
    write_metric(mission, "availability_pct",
                 reason: ::System::ProjectMetricsCollector::UNAVAILABLE_NO_PRODUCER)

    signals = unmeasurable_signals
    expect(signals.map { |s| s.payload["metric"] }).to eq([ "availability_pct" ]),
      "a declaration is a declaration at whichever rung it was made; reading only the " \
      "mission's own configuration here would reopen the bypass the sensor half closed"
  end

  # ── CONSTRAINT 1: the standing machinery ──────────────────────────────────

  it "emits a fingerprint that is stable across sense passes" do
    mission = build_mission(mission_slo: { "p99_latency_ms" => 100 })
    write_metric(mission, "p99_latency_ms",
                 reason: ::System::ProjectMetricsCollector::UNAVAILABLE_NO_PRODUCER)

    first  = unmeasurable_signals.map(&:fingerprint)
    second = unmeasurable_signals.map(&:fingerprint)

    expect(first).to eq(second)
    expect(first).to eq([ "project_target_unmeasurable:#{mission.id}:p99_latency_ms" ]),
      "DecisionEngine#recently_decided? and System::Fleet::SignalState both key on this " \
      "string; anything varying per tick turns the standing lane back into a per-tick flood"
  end

  # ── EQUALITY ORACLE ───────────────────────────────────────────────────────
  #
  # A subset assertion would pass while the lane also fired on three metrics it
  # should not. Declare EVERY service-level target on one mission, make every
  # backing metric producerless, and pin the exact set.
  it "reports every declared target with no producer and nothing else" do
    mission = build_mission(mission_slo: {
      "p99_latency_ms" => 100,
      "availability_pct" => 99.9,
      "cost_ceiling_usd" => 50,
      "min_throughput_bytes_per_s" => 1000
    })

    write_metric(mission, "p99_latency_ms",
                 reason: ::System::ProjectMetricsCollector::UNAVAILABLE_NO_PRODUCER)
    write_metric(mission, "availability_pct",
                 reason: ::System::ProjectMetricsCollector::UNAVAILABLE_NO_PRODUCER)
    # Declared, but MEASURED — must not appear.
    write_metric(mission, "cost_usd_mtd", observed: 10.0)
    # Declared, unavailable, but the sampler works — must not appear.
    write_metric(mission, "sdwan_throughput_bytes_per_s",
                 reason: ::System::ProjectMetricsCollector::UNAVAILABLE_NO_DATA)

    expect(unmeasurable_signals.map { |s| s.payload["metric"] }.sort)
      .to eq([ "availability_pct", "p99_latency_ms" ])
  end

  # A mission with NO metric rows at all has not been sampled yet. Absence of a
  # row is not evidence of a missing producer, and treating it as such would
  # fire on every mission in the tick between its creation and the collector's
  # first pass.
  it "stays silent for a mission the collector has never sampled" do
    build_mission(mission_slo: { "p99_latency_ms" => 100 })

    expect(unmeasurable_signals).to be_empty,
      "no row means not yet sampled, which is not the same as no producer"
  end
end

# ── THE LANE END TO END ─────────────────────────────────────────────────────
#
# The examples above prove the SENSOR emits a stable fingerprint. That is the
# sensor's whole contribution to constraint 1, but it is not the constraint:
# what the driver asked for is that this lane rides the standing-signal
# machinery rather than emitting per tick, and the machinery is generic code
# proven for ONE representative kind (system.cert_expiring, in
# standing_signal_hygiene_spec). "Generic code works for my kind too" is an
# inference, and inferring it is how a notify-only lane ends up flooding or
# silently blocked. So drive the real DecisionEngine over THIS kind.
#
# Both halves are asserted, because either alone is worthless: the event stream
# must be throttled AND the standing condition must reach a person.
RSpec.describe "the unmeasurable-target lane's standing behaviour" do
  let(:account)   { create(:account) }
  let!(:operator) { create(:user, account: account) }
  let(:agent)     { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service)   { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
  let(:engine)    { System::Fleet::DecisionEngine.new(autonomy_service: service) }

  # The lane's declared owner. Without the agent the binding falls back to
  # Fleet Autonomy with a fleet.owner_agent_missing event, which would make
  # this pass for the wrong reason — the gate would be a different agent's.
  let!(:owner) do
    create(:ai_agent, account: account, agent_type: "monitor", name: "Capacity Manager")
  end

  let!(:chain) do
    create(:ai_approval_chain, account: account, trigger_type: "autonomy_action",
                               status: "active", name: "Fleet Autonomy Chain")
  end

  # Cross-tick dedup is Rails.cache-backed and the memory_store is shared
  # across examples, so the standing path only runs from a clean cache.
  before do
    Rails.cache.clear
    Ai::InterventionPolicy.create!(
      account: account, ai_agent_id: owner.id, scope: "agent",
      action_category: "project.target_unmeasurable_investigate",
      policy: "notify_and_proceed", is_active: true
    )
    SiteSetting.set("system.fleet.signal_state.escalate_after_ticks", 2, setting_type: "integer")
    SiteSetting.set("system.fleet.signal_state.heartbeat_seconds", 3600, setting_type: "integer")
  end

  let(:fingerprint) { "project_target_unmeasurable:m-1:p99_latency_ms" }

  def tick!
    engine.decide(
      kind: System::Fleet::Sensors::ProjectSloSensor::UNMEASURABLE_SIGNAL_KIND,
      severity: :low,
      payload: { "mission_id" => "m-1", "metric" => "p99_latency_ms",
                 "target" => 100.0, "unavailable_reason" => "no_producer" },
      fingerprint: fingerprint
    )
  end

  it "throttles the deduped event stream instead of emitting one per tick" do
    6.times { tick! }

    # NON-VACUITY FIRST. "<= 1 event" is also what a lane blocked at the gate
    # produces, so anchor on the state row: it exists only if the ticks
    # actually reached the dedupe path and were counted there.
    state = System::Fleet::SignalState.find_by(account_id: account.id, fingerprint: fingerprint)
    expect(state).to be_present, "no state row means the ticks never reached the dedupe path"
    expect(state.tick_count).to be >= 1

    deduped = System::FleetEvent.where(account_id: account.id, kind: "decision.deduped")
                                .select { |e| e.payload["fingerprint"] == fingerprint }
    expect(deduped.size).to be <= 1,
      "a standing target gap re-detected every 60s must not put an event on the stream every " \
      "60s — that is the 29k/day flood app-2 removed, reintroduced through a new lane"
  end

  it "reaches an operator exactly once and then goes quiet" do
    6.times { tick! }

    approvals = Ai::ApprovalRequest.where(account_id: account.id)
    expect(approvals.count).to eq(1),
      "a declared target nothing measures is resolved by a person; if the lane never reaches " \
      "one it is the silent-declaration defect again, wearing a signal kind"

    state = System::Fleet::SignalState.find_by(account_id: account.id, fingerprint: fingerprint)
    expect(state.escalation_count).to eq(1)

    approvals_before = approvals.count
    6.times { tick! }
    expect(Ai::ApprovalRequest.where(account_id: account.id).count).to eq(approvals_before)
    expect(state.reload.escalation_count).to eq(1)
  end

  # The category is in RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES
  # precisely so this stays zero. A pending outcome here would be scored
  # ineffective every settle window until F3-11 manufactured a
  # fleet.remediation_stuck for a lane that never acted and cannot act.
  it "records no remediation outcome, because it actuates nothing" do
    6.times { tick! }

    # Same non-vacuity problem: zero outcomes is also what a blocked lane
    # yields. The approval row proves the lane ran and PROCEEDED.
    expect(Ai::ApprovalRequest.where(account_id: account.id).count).to eq(1)

    expect(System::Fleet::RemediationOutcome.where(account_id: account.id,
                                                   fingerprint: fingerprint).count).to eq(0)
  end
end
