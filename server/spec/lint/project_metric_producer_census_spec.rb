# frozen_string_literal: true

require "rails_helper"
require_relative "../support/project_metric_samplers"
require "pathname"

# Campaign 01a07025 — the census of METRICS THIS PLATFORM PROMISES TO SAMPLE.
#
# ══ THE PATTERN THIS EXISTS TO CATCH ══════════════════════════════════════
#
# Five separate times in one session this campaign found machinery that
# exists, passes review, and has never executed: a duty service with zero
# callers, a cron gated by a setting no seed sets, an eligibility query joining
# rows nothing creates, a health action with no schedule, and a ladder rung
# with no way to fill it. Every one was found by a person noticing. That does
# not scale.
#
# The common shape is a DECLARED CAPABILITY WITH A MISSING ACTIVATION EDGE.
# Most of the fleet's edges are already guarded, and this file deliberately
# does not re-guard them:
#
#   sensor kind  -> DecisionEngine binding
#       spec/docs/fleet_sensors_signal_kinds_spec.rb, Oracle E,
#       "reconciles against the DecisionEngine's bindings"
#       ("emitted but bound to no action category")
#   binding      -> InterventionPolicy row
#       spec/services/system/fleet/routed_lane_policy_coherence_spec.rb
#       ("seeds an intervention policy row for EVERY action_category the
#        platform routes to")
#   executor     -> Ai::Skill row -> Ai::AgentSkill
#       spec/db/seeds/system_skills_seed_binding_coverage_spec.rb
#   SDWAN executor -> gate site
#       spec/services/sdwan/executors/action_category_coherence_spec.rb
#       ("names every executor at at least one gate site, or records it as
#        composition-only")
#
# The edge NOBODY guarded is the one that produced today's finding:
#
#   metric a sensor reads  ->  a sampler that actually measures it
#
# `p99_latency_ms` has been declared in METRIC_TYPE_MAP, written as a row every
# tick, read by ProjectSloSensor, and compared against a target with a shipped
# default of 250ms — while nothing on this platform has ever measured latency.
# The lane could not fire, and every structural check above was green, because
# every structural edge it has IS present. Only the measurement is missing.
#
# ══ WHAT IS AND IS NOT CHECKABLE HERE ═════════════════════════════════════
#
# "A sensor whose inputs no producer writes" is NOT decidable in general — a
# sensor's inputs are arbitrary ActiveRecord queries and the producers are
# anything that writes those tables. It IS decidable for the ONE telemetry
# convention the platform consolidated on (System::Slo::TelemetryAdapter's own
# comment records that consolidation): a metric flows METRIC_TYPE_MAP ->
# #sample_one -> System::ProjectMetric -> ProjectSloSensor, and every hop is a
# literal in one of two files. That is the boundary of this census, stated so
# nobody reads a green run as "no sensor reads anything unproduced".
#
# The fourth candidate — "a setting that gates a live path and that no seed
# sets" — is deliberately absent. Nearly every fleet SiteSetting read is
# UNSET BY DESIGN and falls back to a constant; that is the tuning convention,
# not a defect. Separating "tunes a threshold with a fallback" from "gates a
# path and defaults off" needs dataflow analysis, not a scan, so a grep-shaped
# version of it would be almost entirely false positives and would be relaxed
# into uselessness within a week.
#
# ══ SHAPE ═════════════════════════════════════════════════════════════════
#
# Derived, never restated: DECLARED reads the live constant, WIRED and READ
# come from the source bytes of the two files that own them. Every scan
# carries a vacuity guard, because a scan that silently matches nothing makes
# every equality below trivially true — this project has shipped that mistake.
#
# BASELINED, not swept: the one existing offender is listed with its reason and
# an evidence token that must really appear in a named file, so an entry cannot
# claim a justification the tree does not contain. Both equalities are
# two-directional, so a NEW unproduced metric reddens and a baselined metric
# that GAINS a producer also reddens. The number can only go down.
RSpec.describe "System::ProjectMetric producer census" do
  # spec/lint/ -> the extension's server/ root. Every relative path below is
  # taken from there, which is where both census targets live.
  SERVER_ROOT = Pathname.new(__dir__).join("..", "..").cleanpath

  COLLECTOR_REL = "app/services/system/project_metrics_collector.rb"
  SENSOR_REL    = "app/services/system/fleet/sensors/project_slo_sensor.rb"

  # ── The baseline: metrics DECLARED with no producer, each with its reason ──
  #
  # An entry is not free. `evidence` must be a token that actually appears in
  # `evidence_in`, checked below — the same discipline
  # provider_type_writer_census_spec.rb uses so a census entry cannot assert a
  # guard the code does not have.
  UNPRODUCED_BASELINE = {
    "p99_latency_ms" => {
      why: "Nothing on this platform measures workload latency. The node agent " \
           "measures cpu from /proc/stat and memory from memory_free_kb; there is no " \
           "prober. The intended transport (System::Slo::TelemetryAdapter, FleetEvent " \
           "kind metric.latency_ms) was ruled DORMANT on 2026-08-23 and its own comment " \
           "says not to wire a producer to revive it. SDWAN flow samples carry byte and " \
           "packet counters, not timings. Reviving this means building a prober from " \
           "nothing, which is an operator decision, not a loose end.",
      evidence: "IMP-6355c5adc382",
      evidence_in: "app/services/system/slo/telemetry_adapter.rb",
      # The decision is enforced, not merely written down.
      ratchet: "spec/services/system/slo/dormancy_guard_spec.rb"
    }
  }.freeze

  def self.read(rel)
    path = SERVER_ROOT.join(rel)
    raise "census target missing: #{rel}" unless path.exist?

    path.read
  end

  # WIRED = the metrics #sample_one dispatches to a real sampler. Everything
  # else falls to its `else unavailable_sample(...)` arm, which is the
  # collector's honest "no telemetry backend wired" record.
  #
  # MOVED to spec/support/project_metric_samplers.rb, not copied: the note
  # census in project_metrics_collector_unavailable_reason_spec.rb needs the
  # same set to assert that the default note reaches only metrics that
  # genuinely have no sampler, and two hand-rolled parsers of one dispatch are
  # how the two oracles come to disagree about what "wired" means. The
  # extraction follows spec/support/fleet_signal_kinds.rb, which exists for
  # exactly this on the sensor side.
  def self.wired_metrics
    ProjectMetricSamplers.wired
  end

  # READ = the metric names ProjectSloSensor pulls out of the ProjectMetric
  # rows. #sample_from_db IS the mapping between the canonical metric
  # vocabulary and the sensor's own observation keys, so scanning it is reading
  # the mapping rather than re-stating it.
  def self.sensor_read_metrics
    body = read(SENSOR_REL)[/def sample_from_db\b.*?\n        end\n/m]
    raise "could not locate #sample_from_db — the census would be vacuous" if body.nil?

    body.scan(/by_name\["([a-z0-9_]+)"\]/).flatten.uniq
  end

  let(:declared) { ::System::ProjectMetricsCollector::METRIC_TYPE_MAP.keys }
  let(:wired)    { self.class.wired_metrics }
  let(:read_by_sensor) { self.class.sensor_read_metrics }

  # ── Vacuity guards ────────────────────────────────────────────────────────
  # Every equality below is trivially true against an empty scan. These are the
  # positive controls that stop a collapsed regex reading as a clean census.

  it "finds a plausible number of declared, wired and read metrics" do
    expect(declared.size).to be >= 8,
                             "METRIC_TYPE_MAP collapsed — every equality here would be vacuous"
    expect(wired.size).to be >= 7,
                          "the #sample_one scan matched almost nothing — it would report every metric unproduced"
    expect(read_by_sensor.size).to be >= 7,
                                   "the #sample_from_db scan collapsed — the consumer oracle would be vacuous"
  end

  it "scans only real metric names — nothing the collector does not declare" do
    # The scans must not invent names either. A regex that drifted onto some
    # other `when` or `by_name[...]` would inflate the wired set and hide a
    # genuinely unproduced metric.
    expect(wired - declared).to eq([]),
                                "the #sample_one scan matched names METRIC_TYPE_MAP does not declare: #{(wired - declared).inspect}"
    expect(read_by_sensor - declared).to eq([]),
                                         "the sensor reads names the collector never writes: #{(read_by_sensor - declared).inspect}"
  end

  # ── Oracle A: the collector's own completeness ────────────────────────────

  it "wires a sampler for every declared metric, except the baselined ones" do
    unproduced = (declared - wired).sort

    expect(unproduced).to eq(UNPRODUCED_BASELINE.keys.sort), <<~MSG
      A metric is DECLARED in METRIC_TYPE_MAP but has no sampler in #sample_one.

      declared with no producer: #{unproduced.inspect}
      baselined:                 #{UNPRODUCED_BASELINE.keys.sort.inspect}

      A row is written for it every tick carrying observed:nil, any sensor that
      reads it can never fire, and every structural check on this platform stays
      green because every structural edge is present. Wire a sampler, or add a
      baseline entry naming why no producer can exist and where that decision is
      recorded. This list may only get SHORTER.
    MSG
  end

  # ── Oracle B: the pattern itself — a consumer reading what nothing writes ──

  it "lets no sensor read a metric that nothing produces, except the baselined ones" do
    dead_reads = (read_by_sensor - wired).sort

    expect(dead_reads).to eq(UNPRODUCED_BASELINE.keys.sort), <<~MSG
      ProjectSloSensor READS a metric that no sampler produces: #{dead_reads.inspect}

      This is the exact shape this census exists to catch — a lane whose every
      structural edge is present and whose measurement is missing, so it passes
      review and never executes.
    MSG
  end

  # ── The baseline cannot lie, and it cannot go stale ───────────────────────

  it "names only metrics the collector actually declares" do
    unknown = UNPRODUCED_BASELINE.keys - declared
    expect(unknown).to eq([]),
                       "baselined metrics that METRIC_TYPE_MAP no longer declares — delete the entries: #{unknown.inspect}"
  end

  it "goes red on a baselined metric that has since GAINED a producer" do
    # The ratchet direction. Without this the baseline is a permanent
    # exemption; with it, wiring latency FORCES the entry out.
    revived = UNPRODUCED_BASELINE.keys & wired
    expect(revived).to eq([]),
                       "these metrics now have a real sampler — remove their baseline entries: #{revived.inspect}"
  end

  it "carries, for every entry, evidence that really exists in the tree" do
    UNPRODUCED_BASELINE.each do |metric, entry|
      expect(entry[:why].to_s.length).to be > 80,
                                         "#{metric}: a baseline entry must explain itself, not just name itself"

      source = self.class.read(entry.fetch(:evidence_in))
      expect(source).to include(entry.fetch(:evidence)),
                        "#{metric}: the entry cites #{entry[:evidence]} in #{entry[:evidence_in]}, " \
                        "which does not contain it — the justification is not where the entry says it is"

      ratchet = SERVER_ROOT.join(entry.fetch(:ratchet))
      expect(ratchet).to exist,
                         "#{metric}: the entry names #{entry[:ratchet]} as the enforcement of its decision, " \
                         "and that file is gone — the decision is now only prose"
    end
  end
end
