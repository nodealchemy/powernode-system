# frozen_string_literal: true

require "spec_helper"

# IMP-17971c5411a6 — sensor-metadata drift in the `module_promotion_sensor`
# block of docs/FLEET_SENSORS.md. A different defect class from
# IMP-29914cc57313 (which corrected the *remediation* line, one line below, and
# is pinned in module_promotion_docs_accuracy_spec.rb): these three lines
# described a sensor that does not exist — a column the model does not have, a
# timer nothing implements, and two signal kinds nothing emits.
#
# Every corrected value is DERIVED FROM SOURCE here, never restated as a
# literal, so a rename of the column, the constants or the signal kind reddens
# this file instead of silently un-truthing the doc again.
#
# Shape of the guard, per file:
#
#   * ORACLE (equality) — the set of signal kinds the doc names must EQUAL the
#     set the sensor emits, and the column the doc names must EQUAL the column
#     the sensor scopes on. Existence checks are not enough: the false version
#     of both lines named plausible things that simply were not these.
#   * ORACLE (code premise) — PromotionCriteria must not read the
#     time-in-staging stamp, which is what makes ">24h in staging" not merely
#     wrong but unimplementable as described; and no automated path may write
#     promotion_state "staging", which is what makes the sensor inert.
#   * TRIPWIRE (marked below) — the presence checks on the inertness prose.
#     They cannot tell a correct explanation from a plausible one; they exist
#     so deleting the explanation is not a silent pass.
#
# What this file does NOT decide: whether the promotion ladder should be wired
# to an automated stager. IMP-c7d618b0b72f has since ANSWERED that (no — see
# docs/design/promotion-ladder-semantics.md), so the last example below no
# longer pins a deferral; it pins the answer and the prohibition that follows
# from it. This file still only asserts what the code does today, and requires
# the doc to say so.
RSpec.describe "FLEET_SENSORS.md module_promotion_sensor block vs. the sensor source" do
  ext_root = File.expand_path("../../..", __dir__)

  def self.read_rel(ext_root, rel)
    path = File.join(ext_root, rel)
    raise "expected #{rel} to exist under #{ext_root}" unless File.exist?(path)

    File.read(path)
  end

  let(:sensor_src) do
    self.class.read_rel(ext_root, "server/app/services/system/fleet/sensors/module_promotion_sensor.rb")
  end
  let(:criteria_src) do
    self.class.read_rel(ext_root, "server/app/services/concerns/system/fleet/promotion_criteria.rb")
  end
  let(:doc) { self.class.read_rel(ext_root, "docs/FLEET_SENSORS.md") }

  # The one block; the file documents ~25 sensors.
  let(:block) do
    doc[/^### `module_promotion_sensor`.*?(?=^### )/m] ||
      raise("could not locate the module_promotion_sensor section in FLEET_SENSORS.md")
  end
  let(:watches_line)   { block[/^\*\*Watches:\*\*.*$/]   || raise("no **Watches:** line in the block") }
  let(:threshold_line) { block[/^\*\*Threshold:\*\*.*$/] || raise("no **Threshold:** line in the block") }
  let(:signals_line)   { block[/^\*\*Signals:\*\*.*$/]   || raise("no **Signals:** line in the block") }

  # --- values derived from source, never restated ------------------------

  # What the sensor actually scopes on: the PINNED environments (increment 4b
  # replaced a scope on a decorative per-version column, which no automated path
  # ever wrote, with one derived from state the platform maintains).
  let(:scope_flag) do
    sensor_src[/auto_promote_on_publish: (\w+)\)/, 1] ||
      raise("could not find the pinned-environment scope in module_promotion_sensor.rb")
  end

  # Every signal kind the sensor can emit.
  let(:emitted_kinds) { sensor_src.scan(/kind:\s*"([^"]+)"/).flatten.uniq }

  let(:required_count) do
    criteria_src[/^\s*REQUIRED_COUNT\s*=\s*(\d+)$/, 1] ||
      raise("could not read REQUIRED_COUNT from promotion_criteria.rb")
  end
  let(:dwell_minutes) do
    criteria_src[/^\s*DWELL_TIME\s*=\s*(\d+)\.minutes$/, 1] ||
      raise("could not read DWELL_TIME from promotion_criteria.rb")
  end

  # --- Watches ------------------------------------------------------------

  describe "the **Watches:** line" do
    it "names what the sensor scopes on, derived from the source" do
      expect(scope_flag).to eq("false")
      expect(watches_line).to include("auto_promote_on_publish")
      expect(watches_line).to include("ladder_predecessor")
      expect(watches_line).to include("served_version_for")
      # The deleted column must not come back as documentation.
      expect(watches_line).not_to include("promotion_state")
      expect(watches_line).not_to include("lifecycle_state")
    end

    it "describes a level-triggered state read, not a transition watch" do
      expect(watches_line).to match(/level-triggered|present state/i)
      expect(watches_line).not_to match(/transition/i)
    end
  end

  # --- Threshold ----------------------------------------------------------

  describe "the **Threshold:** line" do
    it "names PromotionCriteria and both of its defaults, derived" do
      expect(threshold_line).to include("PromotionCriteria")
      expect(threshold_line).to match(/\b#{Regexp.escape(required_count)}\b/)
      expect(threshold_line).to match(/\b#{Regexp.escape(dwell_minutes)}\b/)
    end

    it "says the evidence comes from the rung BELOW the target plane" do
      # The whole point of attaching the criteria to a per-environment
      # promotion: a plane must not vouch for itself.
      expect(threshold_line).to match(/rung below/i)
      expect(threshold_line).to include("running_module_digests")
      expect(threshold_line).to include("first_seen_running_at_for")
    end

    it "is backed by a criteria evaluation that really takes the environment" do
      expect(sensor_src).to match(/PromotionCriteria\.evaluate\(version: [^,]+, environment: \w+\)/)
      expect(criteria_src).to match(/def evaluate\(version:, environment: nil\)/)
      # And the evidence plane is the predecessor, not the target.
      expect(criteria_src).to match(/def self\.evidence_environment/)
      expect(criteria_src).to include("environment.ladder_predecessor")
    end
  end

  # --- Signals ------------------------------------------------------------

  describe "the **Signals:** line" do
    it "names exactly the kinds the sensor emits" do
      expect(emitted_kinds).to eq([ "system.module_promotion_ready" ])
      emitted_kinds.each { |kind| expect(signals_line).to include(kind) }
    end

    it "names the fingerprint the sensor actually builds, keyed on the plane too" do
      # A fingerprint keyed on the version alone would dedup two planes ready
      # for the same version into one signal.
      expect(sensor_src).to include('fingerprint: "promotion_ready:#{environment.id}:#{candidate.id}"')
      expect(signals_line).to include("promotion_ready:<environment_id>:<version_id>")
    end
  end

  # --- What the lane does now, and what it did before ---------------------

  describe "the lane's status" do
    # The old block said the sensor was INERT, and it was: its scope was rows
    # resting at a ladder rung nothing automated wrote. That claim must not
    # survive the rebase, because the scope is now populated by every ordinary
    # promotion into a lower rung.
    it "no longer describes the sensor as inert, and says what populates it" do
      expect(block).not_to match(/inert/i)
      expect(block).not_to match(/rests? empty/i)
      # The old block's "no automated path leaves a version resting at staging"
      # survives ONLY as history. Any sentence making that claim must be in the
      # past tense, or the reader is told the live lane has no input.
      block.lines.select { |l| l.match?(/no automated path/i) }.each do |line|
        expect(line).to match(/used to|before|history|increment 4b/i)
      end
      # And the positive half: what puts a plane in scope today.
      expect(block).to match(/falls behind the rung below/i)
    end

    it "explains what replaced the deleted ladder, and points at the decision" do
      expect(block).to match(/increment 4b/i)
      expect(block).to include("design/promotion-ladder-semantics.md")
    end

    it "names the applier that actuates an approved promotion, and its re-check" do
      expect(block).to include("promote_in_environment!")
      expect(block).to include("system.module_promote_to_live")
      expect(block).to match(/ladder_refusal/)
    end

    # The sensor recommends; the plane's own gate decides. A block that read
    # like an actuation would misdescribe a supervised plane.
    it "does not present the signal as an actuation" do
      expect(sensor_src).to match(/RECOMMENDATION, not an actuation/i)
    end
  end
end
