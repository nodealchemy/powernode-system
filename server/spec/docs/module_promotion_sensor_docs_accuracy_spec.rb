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
# What this does NOT decide: whether the promotion ladder should be wired to
# an automated stager at all. That is IMP-c7d618b0b72f's question. This file
# asserts what the code does today, and requires the doc to say so.
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

  # The column the sensor actually scopes on.
  let(:scope_column) do
    sensor_src[/\.where\((\w+): "staging"\)/, 1] ||
      raise("could not find the staging scope in module_promotion_sensor.rb")
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
    it "names the column the sensor scopes on, and only that column" do
      # EQUALITY, not inclusion: the false line named
      # `NodeModuleVersion.lifecycle_state`, a column that exists nowhere, and
      # an inclusion check on the real name would have passed a line naming
      # both.
      documented = watches_line.scan(/NodeModuleVersion\.(\w+)/).flatten.uniq
      expect(documented).to eq([ scope_column ])

      # The capture above only sees `NodeModuleVersion.`-prefixed names, so a
      # rewrite naming the column bare ("the `lifecycle_state` column, re-read
      # each tick") would pass it. Name the false column explicitly too.
      expect(watches_line).not_to match(/\blifecycle_state\b/)
    end

    it "does not describe the sensor as watching transitions" do
      # The sensor has no memory between ticks — `sense` re-reads whatever is
      # sitting in the scope. "transitions (staging -> blessed)" told a reader
      # to expect an edge-triggered watcher.
      expect(watches_line).not_to match(/transitions?\b/i)
    end
  end

  # --- Threshold ----------------------------------------------------------

  describe "the **Threshold:** line" do
    it "names PromotionCriteria and both of its default constants" do
      expect(threshold_line).to include("PromotionCriteria")
      expect(threshold_line).to match(/\b#{Regexp.escape(required_count)}\b/)
      expect(threshold_line).to match(/\b#{Regexp.escape(dwell_minutes)}\b/)
    end

    it "states no elapsed-time-in-staging threshold" do
      # The false line promised ">24h in staging". Any elapsed-time gate here
      # is the same claim in different clothes, so the alternative
      # denominations a rewrite would reach for are covered too.
      expect(threshold_line).not_to match(/\d+\s*(h\b|hrs?\b|hours?\b)/i)
      expect(threshold_line).not_to match(/\b(days?|weeks?)\b/i)
      expect(threshold_line).not_to match(/\bin\s+`?staging`?\s+(for|without)\b/i)
    end

    it "is backed by criteria and a sensor that never read the time-in-staging stamp" do
      # CODE PREMISE for the example above: an elapsed-time-in-staging gate
      # would have to consult staging_baked_at (the only column recording when
      # a version entered staging; NodeModuleVersion#promote_to! stamps it).
      # Both files, not just the criteria: the review of this task pointed out
      # that such a gate is at least as naturally written as a scope on the
      # sensor (`.where("staging_baked_at < ?", 24.hours.ago)`), and a
      # criteria-only premise stays green through exactly that change while
      # the doc line it backs goes false.
      expect(criteria_src).not_to include("staging_baked_at")
      expect(sensor_src).not_to include("staging_baked_at")
    end
  end

  # --- Signals ------------------------------------------------------------

  describe "the **Signals:** line" do
    it "names exactly the kinds the sensor emits" do
      # EQUALITY. The false line named `module.promotion_ready` (wrong
      # namespace) and `module.promotion_stalled` (emitted by nothing, in this
      # sensor or any other). Matching backticked `system.`-prefixed tokens
      # deliberately skips the severity (`:medium`) and the fingerprint
      # (`promotion_ready:<version_id>`), neither of which is a kind; digits
      # are in the class because an un-namespaced or `_v2`-suffixed name must
      # still be VISIBLE to the comparison rather than skipped into a pass.
      documented = signals_line.scan(/`(system\.[a-z0-9_.]+)`/).flatten
      expect(documented).to eq(emitted_kinds)

      # Second net: any dotted backticked token on the line must be one of the
      # emitted kinds. Catches a fake kind written without the `system.`
      # namespace, which the capture above cannot see at all.
      expect(signals_line.scan(/`([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)`/).flatten).to eq(emitted_kinds)
    end

    it "does not resurrect a second, non-existent kind by name" do
      # Case-insensitive and block-wide: the review of this task noted the
      # case-sensitive form let `System.Module_Promotion_Stalled` through both
      # this backstop and the lowercase capture above.
      expect(block).not_to match(/promotion_stalled|module_promotion_pending/i)
    end
  end

  # --- Inertness: the premise, then the prose ------------------------------

  describe "the sensor's scope" do
    # The scan set for both examples below. Each glob is asserted separately:
    # a single `sources.not_to be_empty` stays green when one glob goes empty
    # (a directory renamed or moved out of the extension), silently retiring
    # that arm of the scan.
    let(:source_globs) do
      { "server/app" => "server/app/**/*.rb",
        "server/lib" => "server/lib/**/*.rb",
        "server/db/seeds" => "server/db/seeds/**/*.rb" }
    end
    let(:sources) do
      source_globs.map do |label, glob|
        found = Dir[File.join(ext_root, glob)]
        raise "scan set is empty for #{label} — the guard below would be vacuous" if found.empty?

        found
      end.flatten
    end

    # ORACLE (equality on the CALLER SET). `NodeModuleVersion#promote_to!` is
    # the only method that moves a version along the ladder, so the question
    # "can anything automated put a row in this sensor's scope" is a question
    # about who can call it.
    #
    # This replaced a literal-argument regex (`promote_to!("staging")`) that
    # the independent review showed could never match: all four call sites
    # pass a VARIABLE, so the old form matched nothing today and would have
    # matched nothing after a regression either — green against the very
    # change it existed to catch. Pin the call sites instead; adding a fifth
    # is what an automated stager would look like, whatever it passes.
    it "can be written only from the four known promote call sites" do
      callers = sources.select { |path| File.read(path).match?(/\.promote_to!\(|ModulePromotionService\.promote!/) }
                       .map { |path| path.delete_prefix("#{ext_root}/") }
                       .sort

      expect(callers).to eq([
        # operator REST: POST /api/v1/system/node_module_versions/:id/promote
        "server/app/controllers/api/v1/system/node_module_versions_controller.rb",
        # operator/agent MCP: system_promote_module_version
        "server/app/services/ai/tools/system_fleet_tool.rb",
        # the one AUTOMATED caller — and it targets "blessed", never "staging",
        # i.e. it consumes this sensor's output rather than producing its input.
        "server/app/services/system/fleet/decision_engine.rb",
        "server/app/services/system/fleet/module_promotion_service.rb"
      ])
    end

    # ORACLE (literal write shapes), widened past the keyword form after the
    # review enumerated what the narrow version missed.
    #
    # KNOWN BLIND SPOT, stated rather than papered over: a write whose value is
    # a variable is invisible to any regex of this kind, and one such writer
    # exists — server/db/seeds/example_custom_module.rb walks a version through
    # `%w[staging blessed live]` with `update!(promotion_state: target_state)`.
    # It is a hand-run example seed (no orchestrator references it) and it does
    # not rest at `staging`, so the doc's conclusion holds; the doc names it
    # explicitly rather than relying on this example to have caught it.
    it "is written by no literal automated writer" do
      # `(?<!where\()` lets the sensor's own `.where(promotion_state:
      # "staging")` -- a READ -- through while catching assignment shapes.
      write_shapes = [
        /(?<!where\()promotion_state:\s*["']staging["']/,   # create!/update!/new keyword
        /promotion_state\s*=\s*["']staging["']/,            # bare attribute assignment
        /target_state:\s*["']staging["']/,                  # ModulePromotionService.promote!
        /update_columns?\(\s*:promotion_state,\s*["']staging["']/,
        /write_attribute\(\s*:promotion_state,\s*["']staging["']/,
        /promote_to!\(\s*["']staging["']/
      ]

      offenders = sources.select { |path|
        src = File.read(path)
        write_shapes.any? { |shape| src.match?(shape) }
      }.map { |path| path.delete_prefix("#{ext_root}/") }

      expect(offenders).to eq([])
    end
  end

  describe "the inertness note" do
    # TRIPWIRE (both examples). Presence checks on prose: they prove the
    # explanation was not deleted, not that it is correct. The oracles above
    # carry the correctness claim.
    it "tells the reader the block describes something that does not currently fire" do
      expect(block).to match(/inert/i)
    end

    it "defers the should-it-be-wired question to the task that owns it" do
      expect(block).to include("IMP-c7d618b0b72f")
    end
  end
end
