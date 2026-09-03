# frozen_string_literal: true

require "spec_helper"

# IMP-bdb650b82c65 — the "PromotionCriteria has never evaluated production
# data" claim, and the uncatalogued override event.
#
# IMP-d6826c872d88 made both MANUAL promote paths — the operator REST promote
# (Api::V1::System::NodeModuleVersionsController#promote, behind the module
# versions panel) and the MCP `system_promote_module_version` — run
# PromotionCriteria through System::Fleet::ManualPromotionAdvisory before a
# promote to a gated target state. They warn rather than refuse (operator
# ruling D17), return the verdict, and persist an overridden verdict as a
# `system.module_promotion_criteria_override` FleetEvent. So the criteria ARE
# exercised on production data now — on every manual blessing — and four
# copies of the older claim went false without an edit: the sensor's own
# comment, two places in docs/design/promotion-ladder-semantics.md, and the
# module_promotion_sensor block of docs/FLEET_SENSORS.md. That block also
# never catalogued the new event kind, which on a fleet below REQUIRED_COUNT
# (default 3) fires on every manual blessing.
#
# Shape of the guard:
#
#   * CODE PREMISE — both manual promote paths really do consult the advisory,
#     and the advisory really does consult PromotionCriteria. If either stops,
#     the corrected prose below is the thing that goes false next.
#   * CONTAINMENT (per file) — the stale claim, in the three wordings it was
#     written in, is absent.
#   * PRESENCE (per file) — the replacement names the event kind, derived from
#     the advisory's EVENT_KIND constant rather than restated, so a rename of
#     the kind reddens this file instead of un-truthing three docs again.
#   * The FLEET_SENSORS.md block must catalogue the kind as a NON-sensor
#     FleetEvent (it is not on the **Signals:** line — the equality oracle in
#     module_promotion_sensor_docs_accuracy_spec.rb pins that line to what the
#     sensor emits — and it must say so in words), and must tell an operator
#     WHY it fires on every manual blessing of a small fleet and which two
#     override keys stop that.
RSpec.describe "PromotionCriteria-is-exercised prose vs. the manual promote paths" do
  ext_root = File.expand_path("../../..", __dir__)

  def self.read_rel(ext_root, rel)
    path = File.join(ext_root, rel)
    raise "expected #{rel} to exist under #{ext_root}" unless File.exist?(path)

    File.read(path)
  end

  let(:advisory_src) do
    self.class.read_rel(ext_root, "server/app/services/system/fleet/manual_promotion_advisory.rb")
  end
  let(:criteria_src) do
    self.class.read_rel(ext_root, "server/app/services/concerns/system/fleet/promotion_criteria.rb")
  end
  let(:controller_src) do
    self.class.read_rel(ext_root, "server/app/controllers/api/v1/system/node_module_versions_controller.rb")
  end
  let(:tool_src) do
    self.class.read_rel(ext_root, "server/app/services/ai/tools/system_fleet_tool.rb")
  end
  let(:sensor_src) do
    self.class.read_rel(ext_root, "server/app/services/system/fleet/sensors/module_promotion_sensor.rb")
  end
  let(:ladder_doc)  { self.class.read_rel(ext_root, "docs/design/promotion-ladder-semantics.md") }
  let(:sensors_doc) { self.class.read_rel(ext_root, "docs/FLEET_SENSORS.md") }

  # --- values derived from source, never restated ------------------------

  let(:event_kind) do
    advisory_src[/^\s*EVENT_KIND\s*=\s*"([^"]+)"/, 1] ||
      raise("could not read EVENT_KIND from manual_promotion_advisory.rb")
  end
  let(:required_count) do
    criteria_src[/^\s*REQUIRED_COUNT\s*=\s*(\d+)$/, 1] ||
      raise("could not read REQUIRED_COUNT from promotion_criteria.rb")
  end
  let(:required_count_key) do
    criteria_src[/^\s*REQUIRED_COUNT_KEY\s*=\s*"([^"]+)"/, 1] ||
      raise("could not read REQUIRED_COUNT_KEY from promotion_criteria.rb")
  end
  let(:dwell_minutes_key) do
    criteria_src[/^\s*DWELL_MINUTES_KEY\s*=\s*"([^"]+)"/, 1] ||
      raise("could not read DWELL_MINUTES_KEY from promotion_criteria.rb")
  end

  # The claim in every wording it has been written in. `evaluated`, `run
  # against` and `executed against` are the three that shipped; `seen` and
  # `touched` are the rewrites a reader would reach for.
  #
  # Named `ADVISORY_` DELIBERATELY: RSpec defines a bare constant in a describe
  # block on Object, so a plain `STALE_CLAIM` here would collide silently with
  # any same-named constant in another spec file — whichever loads second wins,
  # and a green run cannot see it. Same precedent as `TREE_NON_SENSOR_KINDS` in
  # docs_tree_signal_kinds_spec.rb.
  ADVISORY_STALE_CLAIM = /never\s+(?:been\s+)?(?:evaluated|run\s+against|executed\s+against|seen|touched)\s+(?:any\s+)?production\s+data/i

  # Every key the emitter actually writes: the compacted criteria hash plus the
  # actor pair merged after it. Derived, so adding a key to the payload without
  # cataloguing it reddens this file.
  let(:override_payload_keys) do
    m = advisory_src.match(/payload:\s*\{(?<body>.*?)\}\.compact\.merge\((?<merged>.*?)\)/m) ||
        raise("could not locate the override event payload hash in manual_promotion_advisory.rb")

    (m[:body] + m[:merged]).scan(/^\s*(\w+):\s/).flatten.uniq
  end

  let(:sensor_block) do
    sensors_doc[/^### `module_promotion_sensor`.*?(?=^### )/m] ||
      raise("could not locate the module_promotion_sensor section in FLEET_SENSORS.md")
  end
  let(:signals_line) { sensor_block[/^\*\*Signals:\*\*.*$/] || raise("no **Signals:** line in the block") }
  let(:override_paragraph) do
    sensor_block.lines.find { |l| l.include?(event_kind) } ||
      raise("no paragraph in the module_promotion_sensor block names #{event_kind}")
  end
  let(:ladder_section_4_1) do
    ladder_doc[/^### 4\.1 .*?(?=^## |^### |\z)/m] ||
      raise("could not locate section 4.1 in promotion-ladder-semantics.md")
  end

  # --- code premise -------------------------------------------------------

  describe "the premise: the manual promote paths consult PromotionCriteria" do
    it "is consulted by the REST promote and by its MCP twin, through the advisory" do
      expect(controller_src).to include("ManualPromotionAdvisory.evaluate(")
      expect(tool_src).to include("ManualPromotionAdvisory.evaluate(")
      expect(advisory_src).to match(/PromotionCriteria\.(?:advisory|evaluate)\(/)
    end

    it "persists an override under the kind the docs are asked to name" do
      expect(advisory_src).to include("kind: EVENT_KIND")
      expect(event_kind).to start_with("system.")
    end
  end

  # --- containment + presence, per file -----------------------------------

  describe "the sensor's own header comment" do
    it "no longer claims the criteria have never seen production data" do
      expect(sensor_src).not_to match(ADVISORY_STALE_CLAIM)
    end

    it "names the manual path that exercises them and the event it leaves behind" do
      expect(sensor_src).to include("ManualPromotionAdvisory")
      expect(sensor_src).to include(event_kind)
    end
  end

  describe "docs/design/promotion-ladder-semantics.md" do
    it "no longer claims the criteria have never seen production data, anywhere in the note" do
      # File-wide: the claim was made twice (section 3 and section 4.1), and a
      # per-section check would have passed the file after one was fixed.
      expect(ladder_doc).not_to match(ADVISORY_STALE_CLAIM)
    end

    it "redirects section 4.1's shadow-mode pass at the override events" do
      expect(ladder_section_4_1).to include("ManualPromotionAdvisory")
      expect(ladder_section_4_1).to include("`#{event_kind}`")
      # What remains true, and must stay said: the AUTOMATED lane has never
      # decided anything on the criteria's verdict.
      expect(ladder_section_4_1).to match(/automated[^.]*never[^.]*(?:decided|acted)/i)
    end
  end

  describe "docs/FLEET_SENSORS.md module_promotion_sensor block" do
    it "no longer claims the criteria have never seen production data" do
      expect(sensors_doc).not_to match(ADVISORY_STALE_CLAIM)
    end

    it "catalogues the override kind as a FleetEvent that is NOT a sensor signal" do
      expect(sensor_block).to include("`#{event_kind}`")
      # Off the Signals line: the equality oracle in the sibling spec would
      # catch it there too, but this is the claim this file makes.
      expect(signals_line).not_to include(event_kind)
      expect(sensor_block).to match(/not a sensor signal/i)
      expect(sensor_block).to include("ManualPromotionAdvisory")
    end

    it "catalogues every key the emitter writes into the override payload" do
      # Sanity: the derivation found the real hash, not an empty match.
      expect(override_payload_keys).to include("module_name", "version_number", "target_state", "actor_id")

      override_payload_keys.each do |key|
        expect(override_paragraph).to include("`#{key}`"),
                                      "FLEET_SENSORS.md does not name the payload key #{key}"
      end
    end

    it "tells an operator why it fires on every manual blessing of a small fleet, and what stops that" do
      paragraph = override_paragraph

      # The D17 ruling, verbatim in spirit: it warns, it does not refuse.
      expect(paragraph).to match(/\bwarn/i)
      expect(paragraph).to match(/never refuse/i)
      # The default that cannot be met on a 1-2 instance fleet, derived.
      expect(paragraph).to match(/\b#{Regexp.escape(required_count)}\b/)
      expect(paragraph).to match(/every[^.]*manual blessing/i)
      # Both override keys, derived.
      expect(paragraph).to include("`#{required_count_key}`")
      expect(paragraph).to include("`#{dwell_minutes_key}`")
    end
  end
end
