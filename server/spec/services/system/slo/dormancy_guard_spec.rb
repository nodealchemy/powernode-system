# frozen_string_literal: true

require "rails_helper"

# Dormancy ratchet for the SLO telemetry lane — IMP-6355c5adc382, decided
# 2026-08-23: MARK DORMANT, do not build a producer, do not delete. See the
# top-of-class comments on System::Slo::Definition, ScoreEvaluator,
# TelemetryAdapter, and Fleet::Sensors::SloViolationSensor for the narrative.
# The live convention is System::ProjectMetric (cron → SystemFleetReconcileJob
# → FleetAutonomyService.tick! → collect_project_metrics! →
# ProjectMetricsCollector → System::ProjectMetric → ProjectSloSensor →
# DecisionEngine).
#
# What keeps "dormant" true, mechanically, is two absences:
#   (1) nothing outside a spec creates a System::Slo::Definition
#   (2) nothing emits a FleetEvent of kind "metric.latency_ms"
#       (System::Slo::TelemetryAdapter::LATENCY_EVENT_KIND)
# This spec reasserts both on every run, so a lane revival — accidental or
# not — fails loudly here instead of silently re-arming a dead code path.
#
# ============================================================================
# ABSENCE-ORACLE WARNING (read before touching this file)
# ============================================================================
# An absence assertion is green on day one AND green when the scan itself is
# broken (e.g. a glob that resolves to zero files after a directory rename,
# or a regex typo that never matches anything). Those two states are
# indistinguishable unless something proves the scan mechanism actually
# works. Every check below carries its own positive control:
#   - "glob roots are non-empty" — a silently-broken glob path must FAIL,
#     not pass vacuously.
#   - "finds the one known real producer" — the SAME regex used for the
#     absence check, pointed at
#     spec/services/system/fleet/sensors/slo_violation_sensor_spec.rb (the
#     sole `Slo::Definition.create!` call in the repo as of 2026-08-23),
#     must find it.
#   - "each creation-spelling arm matches its own synthetic sample" — most
#     spellings below have NO real occurrence anywhere in the repo (that is
#     the point of the guard), so their regexes are self-tested against a
#     literal sample string instead. This is the mutation-proof surface: if
#     an arm's regex can't even match its own hand-written example, it can
#     never match a real one either.
#
# Two known ways this exact class of guard has failed in THIS repo, both
# checked for below:
#   - a trailing `\b` OUTSIDE a `(?:a|b)` alternation binds to whichever
#     branch matched, and silently drops any branch whose match ends in a
#     non-word character (e.g. `create!` — `\b` right after `!` needs a
#     word char on one side and never gets one when `!` is followed by `(`
#     or whitespace). Every arm below is therefore its OWN regex, not a
#     branch of a shared alternation — no arm's boundary can be shadowed by
#     another arm's shape.
#   - line-anchored patterns (`/^\s*foo:/`) are formatting-blind and miss a
#     compact one-line style. Nothing below is line-anchored; matches are
#     plain substring/regex search over the whole file body.
#
# COVERAGE — creation spellings this guard catches:
#   - Slo::Definition.create!
#   - Slo::Definition.create(...)
#   - Slo::Definition.new
#   - Slo::Definition.find_or_create_by(!)
#   - Slo::Definition.first_or_create(!)
#   - Slo::Definition.find_or_initialize_by (doesn't itself persist, but is
#     the shape that precedes a #save/#save! that does — included as an
#     early-warning arm, not because it alone creates a row)
#   - `slo_definitions.create` / `.build` (association form) — defense in
#     depth only: no model currently declares `has_many :slo_definitions`
#     (confirmed by grep against app/models at spec-write time), so this
#     arm has NO reachable positive control in the current repo. It exists
#     to catch a future `has_many :slo_definitions` + association-create
#     without a literal `Slo::Definition` token at the call site.
#   - ANY other reference to the literal `Slo::Definition` in a file outside
#     the allowlisted dormant set below (belt-and-suspenders: catches any
#     shape at all, including ones not enumerated above, e.g. a chained
#     `.where(...).first_or_create!` where the arm regex above wouldn't
#     match because of the intervening `.where` call)
#
# NOT COVERED — spellings this guard cannot see (found by independent
# review during IMP-6355c5adc382, 2026-08-23 — recorded here rather than
# silently patched over, per the same "don't fake absence" discipline this
# whole file is built on):
#   - decomposed reflection where the substring `Slo::Definition` never
#     appears contiguously, e.g.
#     `Object.const_get(:System).const_get(:Slo).const_get(:Definition)` or
#     `%w[System Slo Definition].join("::").constantize`. The single-string
#     form (`"System::Slo::Definition".constantize.create!`) IS caught —
#     the substring scan still sees it.
#   - a raw SQL INSERT into system_slo_definitions that never mentions the
#     Ruby class name at all (e.g. `ActiveRecord::Base.connection.execute`)
#   - string-built latency kinds, e.g. `"metric." + "latency_ms"` or
#     interpolation — the literal-quote scan below needs the exact
#     characters `"metric.latency_ms"` (or `'...'`) contiguous in one token
#   - db/migrate/*.rb IS now scanned (added after review found the prior
#     version skipped it) for both extensions/system and core server, so a
#     data migration that literally creates a Definition or references
#     `Slo::Definition` is caught; spec/factories and config/initializers
#     are NOT scanned — no factory or initializer references either symbol
#     today (confirmed by grep at spec-write time), so there is no
#     reachable positive control for adding that scan, and skipping it
#     avoids inventing an allowlist for spec/ that this guard doesn't
#     otherwise need.
# ============================================================================
RSpec.describe "SLO telemetry lane dormancy ratchet" do
  KNOWN_PRODUCER_SPEC = Rails.root.join(
    "..", "extensions", "system", "server", "spec", "services", "system",
    "fleet", "sensors", "slo_violation_sensor_spec.rb"
  ).freeze

  # Files allowed to mention `Slo::Definition` — the dormant class itself,
  # its sole reader, and the two files whose doc comments name it while
  # explaining why it never runs. Nothing else may reference it.
  ALLOWLISTED_DEFINITION_FILES = [
    Rails.root.join("..", "extensions", "system", "server", "app", "models", "system", "slo", "definition.rb"),
    Rails.root.join("..", "extensions", "system", "server", "app", "services", "system", "slo", "score_evaluator.rb"),
    Rails.root.join("..", "extensions", "system", "server", "app", "models", "system", "base_record.rb")
  ].map(&:to_s).freeze

  # telemetry_adapter.rb owns LATENCY_EVENT_KIND and documents the
  # convention in its header comment ("kind: \"metric.latency_ms\"") — it is
  # the allowed reader, not a producer, and is excluded from the emission
  # scan below.
  TELEMETRY_ADAPTER_FILE = Rails.root.join(
    "..", "extensions", "system", "server", "app", "services", "system", "slo", "telemetry_adapter.rb"
  ).to_s.freeze

  SOURCE_ROOTS = [
    Rails.root.join("..", "extensions", "system", "server", "app", "**", "*.rb"),
    Rails.root.join("..", "extensions", "system", "server", "lib", "**", "*.rb"),
    Rails.root.join("..", "extensions", "system", "server", "db", "seeds", "**", "*.rb"),
    # Migrations added after independent review (IMP-6355c5adc382, 2026-08-23)
    # found the original version skipped them — a data migration is a
    # plausible, idiomatic place to sneak in a producer.
    Rails.root.join("..", "extensions", "system", "server", "db", "migrate", "**", "*.rb"),
    Rails.root.join("app", "**", "*.rb"),
    Rails.root.join("db", "migrate", "**", "*.rb"),
    Rails.root.join("..", "worker", "app", "**", "*.rb")
  ].freeze

  DEFINITION_CREATION_ARMS = {
    "Slo::Definition.create!" => {
      pattern: /Slo::Definition\.create!/,
      sample: 'System::Slo::Definition.create!(name: "x", node_module: nm)'
    },
    "Slo::Definition.create(" => {
      pattern: /Slo::Definition\.create\(/,
      sample: 'System::Slo::Definition.create(name: "x")'
    },
    "Slo::Definition.new" => {
      pattern: /Slo::Definition\.new\b/,
      sample: 'defn = System::Slo::Definition.new(name: "x")'
    },
    "Slo::Definition.find_or_create_by" => {
      pattern: /Slo::Definition\.find_or_create_by/,
      sample: 'System::Slo::Definition.find_or_create_by!(name: "x")'
    },
    "Slo::Definition.first_or_create" => {
      pattern: /Slo::Definition\.first_or_create/,
      sample: 'System::Slo::Definition.first_or_create!(name: "x")'
    },
    "Slo::Definition.find_or_initialize_by" => {
      pattern: /Slo::Definition\.find_or_initialize_by/,
      sample: 'System::Slo::Definition.find_or_initialize_by(name: "x")'
    },
    "slo_definitions.create/.build (association form)" => {
      pattern: /slo_definitions\.(?:create|build)\b/,
      sample: "node_module.slo_definitions.create!(name: \"x\")"
    }
  }.freeze

  # Arm 1 was widened after independent review (IMP-6355c5adc382, 2026-08-23)
  # found the original `kind:\s*["']metric\.latency_ms["']` form had two
  # live bypasses: (a) aliasing the string to a differently-named constant
  # (`MY_KIND = "metric.latency_ms"` then `kind: MY_KIND`) never puts the
  # literal next to a `kind:` token, and (b) the symbol form
  # (`kind: :"metric.latency_ms"`) puts a `:` between `kind:` and the quote,
  # which the old pattern's `["']` immediately-after-`kind:` requirement
  # rejected. Dropping the `kind:` prefix requirement and matching the
  # quoted literal ANYWHERE in a non-comment line catches both: the alias's
  # own assignment line still contains the quoted literal verbatim, and the
  # symbol form still contains `"metric.latency_ms"` with a quote
  # immediately on each side — only the string-concatenation/interpolation
  # bypass (`"metric." + "latency_ms"`) survives this, see NOT COVERED
  # above. Verified this widening introduces no new false positive against
  # the one prose sentence in the repo that contains the substring without
  # quotes touching it (db/seeds/system_provisioning_mission_template.rb's
  # `"no metric.latency_ms producer wired..."` message — no quote character
  # sits directly adjacent to `metric.latency_ms` there, so it does not
  # match).
  LATENCY_EMISSION_ARMS = {
    '"metric.latency_ms" (quoted literal, any context)' => {
      pattern: /["']metric\.latency_ms["']/,
      sample: 'MY_ALIAS_KIND = "metric.latency_ms"'
    },
    "LATENCY_EVENT_KIND (referenced outside its owner file)" => {
      pattern: /LATENCY_EVENT_KIND/,
      sample: "kind: ::System::Slo::TelemetryAdapter::LATENCY_EVENT_KIND"
    }
  }.freeze

  def scan_files
    SOURCE_ROOTS.flat_map { |glob| Dir.glob(glob) }.uniq
  end

  # Strips full-line `#` comments before pattern matching, so the guard
  # reacts to code, not to doc comments that quote the string/constant for
  # explanatory purposes (e.g. this very file, or telemetry_adapter.rb's
  # own header). A match on a trailing inline comment on an otherwise
  # code line is NOT filtered — over-flagging is the safe failure mode for
  # an absence guard, under-flagging is not.
  def code_body(path)
    File.readlines(path).reject { |line| line.strip.start_with?("#") }.join
  end

  # -- 1. the scan itself must be capable of finding something -------------

  describe "scan mechanism sanity (absence needs its own oracle)" do
    it "resolves every glob root to at least one file" do
      SOURCE_ROOTS.each do |glob|
        files = Dir.glob(glob)
        expect(files).not_to be_empty, "glob root resolved to ZERO files (broken path?): #{glob}"
      end
    end

    it "the known producer spec file exists" do
      expect(File.exist?(KNOWN_PRODUCER_SPEC)).to be(true),
        "expected the known Slo::Definition producer at #{KNOWN_PRODUCER_SPEC} — " \
        "if it moved, this guard's positive control is void and must be repointed"
    end

    it "the Slo::Definition.create! arm finds the one known real producer" do
      body = File.read(KNOWN_PRODUCER_SPEC)
      expect(body).to match(DEFINITION_CREATION_ARMS["Slo::Definition.create!"][:pattern]),
        "the create! pattern did not find its own known positive control — the regex is broken"
    end

    it "every definition-creation arm matches its own synthetic sample independently" do
      DEFINITION_CREATION_ARMS.each do |name, arm|
        expect(arm[:sample]).to match(arm[:pattern]), "arm #{name.inspect} failed to match its own sample: #{arm[:sample].inspect}"
      end
    end

    it "every latency-emission arm matches its own synthetic sample independently" do
      LATENCY_EMISSION_ARMS.each do |name, arm|
        expect(arm[:sample]).to match(arm[:pattern]), "arm #{name.inspect} failed to match its own sample: #{arm[:sample].inspect}"
      end
    end
  end

  # -- 2. no non-spec code creates a Slo::Definition ------------------------

  describe "no non-spec code creates a System::Slo::Definition" do
    it "no file outside the allowlisted dormant set even mentions Slo::Definition" do
      offenders = scan_files.select do |f|
        next false if ALLOWLISTED_DEFINITION_FILES.include?(f)
        code_body(f).include?("Slo::Definition")
      end
      expect(offenders).to be_empty,
        "new Slo::Definition reference(s) outside the dormant allowlist — a producer may have " \
        "been (re)introduced; see IMP-6355c5adc382: #{offenders}"
    end

    it "no allowlisted dormant file contains a creation call, under any covered spelling" do
      DEFINITION_CREATION_ARMS.each do |name, arm|
        ALLOWLISTED_DEFINITION_FILES.each do |f|
          next unless File.exist?(f)
          body = code_body(f)
          expect(body).not_to match(arm[:pattern]),
            "#{File.basename(f)} contains a Slo::Definition creation call (#{name}) — " \
            "the lane is supposed to be dormant (IMP-6355c5adc382, 2026-08-23)"
        end
      end
    end
  end

  # -- 3. nothing emits a metric.latency_ms FleetEvent ----------------------

  describe "nothing emits LATENCY_EVENT_KIND (\"metric.latency_ms\")" do
    it "the kind literal is only ever read, never emitted, outside telemetry_adapter.rb" do
      LATENCY_EMISSION_ARMS.each do |name, arm|
        offenders = scan_files.reject { |f| f == TELEMETRY_ADAPTER_FILE }
                               .select { |f| code_body(f).match?(arm[:pattern]) }
        expect(offenders).to be_empty,
          "found a #{name} emission outside telemetry_adapter.rb — the SLO latency lane " \
          "is supposed to be dormant (IMP-6355c5adc382, 2026-08-23): #{offenders}"
      end
    end

    it "telemetry_adapter.rb itself still contains the literal (mechanism-alive positive control)" do
      body = File.read(TELEMETRY_ADAPTER_FILE)
      expect(body).to match(LATENCY_EMISSION_ARMS['"metric.latency_ms" (quoted literal, any context)'][:pattern])
    end
  end
end
