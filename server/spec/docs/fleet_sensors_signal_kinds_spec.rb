# frozen_string_literal: true

require "spec_helper"

# IMP-e839dd0ffc05 — signal-kind fabrication across docs/FLEET_SENSORS.md.
#
# Twelve `**Signals:**` declarations named dotted kinds that NO sensor emits
# (`instance.silent`, `module.drift_detected`, `cert.rotated`, …, plus
# `system.instance_state_drift`, which the real emitter spells
# `system.instance_state_drifted`). The same fabricated names were repeated in
# the `**Threshold:**` lines one line above and in the architecture diagram's
# `Signals` node. Follow-on from IMP-17971c5411a6, which corrected exactly this
# defect in the `module_promotion_sensor` block ONLY
# (module_promotion_sensor_docs_accuracy_spec.rb pins that block's other
# claims; this file deliberately does not restate them).
#
# WHY IT MATTERS: `DecisionEngine::SIGNAL_BINDINGS` keys on the real `system.*`
# kinds. An intervention policy authored from a fabricated name binds a kind
# that never arrives and fails SILENTLY — no error, no unmatched-kind warning,
# just a lane that never fires.
#
# ─────────────────────────────────────────────────────────────────────────────
# SCOPE: FILE, NOT HEADING — stated deliberately.
#
# The obvious guard reads one `### <sensor>` block. That shape has missed the
# same claim repeatedly: here the fabricated name appeared in the `Threshold:`
# line, in the mermaid `Signals` node ~180 lines above every block, and in the
# `Signals:` line — three places, one of which no per-block guard reads at all.
# Oracle B below therefore sweeps the WHOLE FILE for anything shaped like a
# signal kind, and the emitted set is derived from the whole sensors directory
# rather than from one file. The cost is a maintained allowlist of dotted
# tokens that are not signal kinds (see the classification lists); that cost is the
# point — a new one must be classified deliberately instead of slipping in.
#
# ORACLES (all three are EQUALITIES, never per-kind existence checks — a
# per-kind check cannot see a kind someone adds to the doc later, which is
# exactly how twelve of these accumulated):
#
#   A. Every kind named across ALL `**Signals:**` declarations in the file
#      EQUALS the set the sensors can emit. Catches both directions: a
#      fabricated kind, and a real kind the doc never documents.
#   B. Every backticked dotted token ANYWHERE in the file is either an emitted
#      kind or a real identifier (it appears as a string literal in extension
#      source) or an explicitly classified non-signal token.
#   C. The architecture diagram's `Signals` node names only real namespaces.
#
# Plus non-vacuity guards: an oracle over an empty scan set is green for the
# wrong reason, so every scan set is asserted non-empty and floor-checked.
RSpec.describe "FLEET_SENSORS.md signal kinds vs. the sensors that emit them" do
  ext_root = File.expand_path("../../..", __dir__)

  SENSORS_DIR = "server/app/services/system/fleet/sensors"

  # Dotted backticked tokens in the doc that are deliberately NOT signal kinds.
  # Each is classified; an unclassified newcomer fails Oracle B rather than
  # being waved through.
  #
  # The lists are SEPARATE, and only the first is ever subtracted from a
  # declaration line, because subtraction is an amnesty: a token exempted there
  # can be listed as a sensor's signal and no oracle will object. No member of
  # ATTRIBUTE_REFS is `system.`-prefixed, so none can be mistaken for a kind.
  # The `system.`-prefixed classifications below are exempt at Oracle B only.

  # Model / config attribute references written in dotted prose form, plus the
  # operator-authored GitOps file (a file the USER writes; it exists in no tree
  # here).
  ATTRIBUTE_REFS = %w[
    autonomy_config.interval_seconds
    brief.budget_cap_usd_monthly
    brief.latency_targets_ms.p99
    payload.reason
    payload.remediation_action
    peer.updated_at
    system_sdwan_services.health_state
    fleet.yaml
  ].freeze

  # SiteSetting keys. Real, but assembled by interpolation in the sensors
  # (`"system.sdwan.ovn.#{key}"`), so no whole-key string literal exists to
  # match against.
  SETTING_KEYS = %w[
    system.sdwan.ovn.probe_denied_cidrs
    system.sdwan.ovn.stall_after_seconds
  ].freeze

  # Action categories the DecisionEngine dispatches — NOT signals. A
  # `**Threshold:**` line may name one to draw exactly that contrast
  # ("the rotation is an ACTION, not a signal"). Asserted below to be real and
  # to be disjoint from the emitted set, so this list cannot launder a
  # fabricated signal kind by relabelling it an action.
  ACTION_KINDS = %w[ system.cert_rotate ].freeze

  # A real `FleetEvent` kind that no SENSOR emits — `CanaryModuleService` writes
  # it and `honeypot_access_sensor` READS it. Deliberately NOT subtracted from
  # any declaration line: it is documented on an `**Input:**` line precisely so
  # that listing it as a sensor's signal stays a failure.
  NON_SENSOR_KINDS = [ "system.honeypot_triggered" ].freeze

  # The fabrications, kept rather than deleted so an operator who bound a policy
  # to one can find it — the repo's matched-pair convention: the false claim is
  # named AND its correction stands beside it. IMP-e839dd0ffc05 withdrew the
  # first 27; `system.runtime_docker_tls_rotate` was withdrawn by the 2026-05-19
  # audit (registered, seeded nowhere, no executor).
  #
  # Two things are asserted about this list, both equalities:
  #   * no member may be an emitted kind (a RATCHET — if one is ever built, this
  #     guard reddens and forces the doc to move it out of the withdrawal note);
  #   * outside the correction note, the doc may not mention any of them, so a
  #     fabrication cannot creep back into a sensor block under cover of being
  #     "already listed as withdrawn".
  WITHDRAWN_TOKENS = %w[
    cert.expired cert.expiring cert.rotated
    config.drift_detected config.drift_resolved
    gitops.drift_detected gitops.drift_resolved
    honeypot.access honeypot.access_attempted honeypot.access_blocked
    instance.recovered instance.silent
    module.drift_detected module.drift_resolved
    project.cost_breach project.drift project.slo_violation
    sdwan.bgp_recovered sdwan.bgp_unhealthy
    sdwan.peer_drift sdwan.peer_drift_detected sdwan.peer_drift_resolved
    sdwan.vip_holder_recovered sdwan.vip_holder_silent
    slo.recovered slo.violated
    system.instance_state_drift
    system.runtime_docker_tls_rotate
  ].freeze

  # ── the authoritative emitted set, derived from source ────────────────────

  # Every signal kind the registered fleet sensors can emit.
  #
  # Parsed rather than restated. It resolves the three shapes actually present,
  # because a naive `kind: "..."` scan gets this wrong in BOTH directions: it
  # misses the ternary in sdwan_bgp_session_health_sensor.rb (two kinds) and
  # the `SIGNAL_KIND` constant in federation_peer_liveness_sensor.rb (one),
  # while wrongly counting honeypot_access_sensor.rb's
  # `.where(kind: "system.honeypot_triggered")` — a READ of an event another
  # service writes, not an emit.
  def self.emitted_kinds(ext_root)
    files = Dir[File.join(ext_root, SENSORS_DIR, "*.rb")]
             .reject { |p| File.basename(p) == "base_sensor.rb" }
    raise "no sensor sources found under #{SENSORS_DIR} — every oracle below would be vacuous" if files.empty?

    per_file = files.to_h do |path|
      src = File.read(path)
      # Only SIGNAL_KIND-style constants. A blanket `CONST = "system.…"` scan
      # would also pick up boot_lkg_arm_sensor.rb's `SETTING_PREFIX =
      # "system.boot_lkg"` if it ever drifted within reach of a `kind:`,
      # silently adding a SiteSetting prefix to the emitted set.
      consts = src.scan(/^\s*([A-Z][A-Z0-9_]*(?:SIGNAL|KIND)[A-Z0-9_]*)\s*=\s*"(system\.[a-z0-9_.]+)"/).to_h
      found = []
      src.to_enum(:scan, /\bkind:/).each do
        off = Regexp.last_match.begin(0)
        # Skip QUERY calls: honeypot_access_sensor.rb's
        # `.where(… kind: "system.honeypot_triggered")` is a READ of the event
        # log, not an emit. Keyed on the nearest preceding call name rather than
        # a same-line `where(` test, so a read wrapped across lines is still
        # excluded.
        #
        # Stated as an exclusion rather than a `signal(`-only allowlist, which
        # was the first version and was WRONG: gitops_drift_sensor.rb:44 builds
        # its signal as a bare Hash literal inside an array, with no builder
        # call in front of it at all, and an allowlist silently dropped that
        # sensor's only kind.
        caller_name = src[[ off - 400, 0 ].max...off].scan(/\b([a-z_]+)\(/).last&.first
        next if caller_name&.match?(/\A(where|find_by|exists|pluck|count|select|order)\z/)

        # The kind's own argument only: stop at the next keyword argument.
        region = src[off, 400].split(/\n\s*[a-z_]+:\s/, 2).first
        found.concat(region.scan(/"(system\.[a-z0-9_.]+)"/).flatten)
        found.concat(region.scan(/\b([A-Z][A-Z0-9_]{2,})\b/).flatten.filter_map { |c| consts[c] })
      end
      [ path, found.uniq ]
    end

    # PER-FILE non-vacuity. A bare total floor lets the parser lose every kind
    # of one sensor and stay green on the strength of the other thirty; this
    # names the sensor that went quiet.
    silent = per_file.select { |_, found| found.empty? }.keys.map { |p| File.basename(p) }
    raise "parsed no emitted kind from: #{silent.join(', ')} — the parser has stopped matching" if silent.any?

    per_file.values.flatten.uniq.sort
  end

  EMITTED = emitted_kinds(File.expand_path("../../..", __dir__)).freeze

  let(:doc) do
    path = File.join(ext_root, "docs/FLEET_SENSORS.md")
    raise "expected docs/FLEET_SENSORS.md to exist under #{ext_root}" unless File.exist?(path)

    File.read(path)
  end

  # Extension source, MINUS the hand-run `example_*` seeds. Those are
  # demonstration scripts no orchestrator invokes, and one of them
  # (db/seeds/example_honeypot.rb) writes a FleetEvent with the fabricated kind
  # `honeypot.access_attempted` — so including them would let a doc claim cite
  # a seed that never runs as evidence the platform emits the kind.
  let(:source) do
    paths = Dir[
      File.join(ext_root, "server/app/**/*.rb"),
      File.join(ext_root, "server/lib/**/*.rb"),
      File.join(ext_root, "server/db/seeds/**/*.rb")
    ].reject { |p| File.basename(p).start_with?("example_") }
    raise "extension source scan set is empty — Oracle B would be vacuous" if paths.size < 100

    paths.map { |p| File.read(p) }.join("\n")
  end

  # ── Oracle A: the **Signals:** declarations, file-wide ────────────────────

  # Every `**Signals:**` declaration in the file, single-line and bulleted
  # multi-line alike, flattened to the dotted tokens it names.
  let(:declared_kinds) do
    lines = doc.lines
    blocks = lines.each_index.select { |i| lines[i].start_with?("**Signals:**") }
    raise "found no **Signals:** declarations — Oracle A would be vacuous" if blocks.size < 25

    blocks.flat_map { |i|
      region = +lines[i]
      j = i + 1
      # A bulleted declaration continues over blank-separated `- ` items.
      while j < lines.size && (lines[j].start_with?("- ", "  ") ||
                               (lines[j].strip.empty? && lines[j + 1].to_s.start_with?("- ")))
        region << lines[j]
        j += 1
      end
      region.scan(/`([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)`/).flatten
    }.uniq.sort - ATTRIBUTE_REFS
  end

  # Every dotted token on a `**Threshold:**` line. These lines make the SAME
  # claim as a Signals line in different words ("… → `X` signal"), and the
  # original defect wrote the fabricated name into both — so guarding only
  # Signals leaves half the claim unguarded.
  let(:threshold_tokens) do
    lines = doc.lines.select { |l| l.start_with?("**Threshold:**") }
    raise "found no **Threshold:** lines — the threshold oracle would be vacuous" if lines.size < 15

    lines.flat_map { |l| l.scan(/`([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)`/).flatten }.uniq.sort - ATTRIBUTE_REFS
  end

  # The correction note under `## Sensor Reference` — the one region allowed to
  # name a withdrawn kind. Bounded by the blockquote itself, not by a line
  # count, so editing the note cannot silently widen the exemption.
  let(:correction_note) do
    doc[/^## Sensor Reference\n\n((?:^>.*\n)+)/, 1] ||
      raise("could not locate the signal-kind correction note — the containment oracle would be vacuous")
  end

  it "names, across every **Signals:** declaration, exactly the kinds the sensors emit" do
    # EQUALITY in both directions. `-` and `|` are spelled out so a failure
    # says WHICH side is wrong rather than dumping two 40-element arrays.
    expect(declared_kinds - EMITTED).to eq([]),
      -> { "documented but emitted by no sensor: #{(declared_kinds - EMITTED).inspect}" }
    expect(EMITTED - declared_kinds).to eq([]),
      -> { "emitted but named in no **Signals:** declaration: #{(EMITTED - declared_kinds).inspect}" }
    expect(declared_kinds).to eq(EMITTED)
  end

  it "names, on every **Threshold:** line, only emitted kinds and classified non-signals" do
    # The hole the first version of this file left open, found in review: a
    # `**Threshold:**` line could read "→ `system.sdwan_failover` signal, and on
    # recovery a `system.sdwan_peer_remediate` signal" and stay green, because
    # Oracle A never reads these lines and Oracle B accepts any token that is a
    # string literal in source — which every action category is. That is the
    # ORIGINAL defect shape (the fabricated name sat in the Threshold line too).
    expect(threshold_tokens - EMITTED - ACTION_KINDS - SETTING_KEYS).to eq([]),
      -> { "Threshold lines name unclassified tokens: #{(threshold_tokens - EMITTED - ACTION_KINDS - SETTING_KEYS).inspect}" }

    # ACTION_KINDS is the only classification that could launder a fabricated
    # signal, so it is held to both halves of its own definition: a real action
    # category in source, and NOT something a sensor emits.
    expect(ACTION_KINDS & EMITTED).to eq([])
    ACTION_KINDS.each do |a|
      expect(source).to include(%("#{a}")),
        -> { "#{a} is classified as an action category but appears in no source string" }
    end

    # …and whatever a line calls a "signal" must actually be one, whichever
    # list it came from. Closes the relabelling route in the other direction.
    doc.lines.select { |l| l.start_with?("**Threshold:**", "**Signals:**") }.each do |line|
      # `X` signal — the token IMMEDIATELY followed by the word, nothing
      # between but whitespace. A looser window matched the sentence "the
      # rotation is an ACTION (`system.cert_rotate`), not a signal", i.e. it
      # read a denial as a claim.
      line.scan(/`([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)`\s+signals?\b/).flatten.each do |tok|
        expect(EMITTED).to include(tok),
          -> { "called a signal but emitted by no sensor: #{tok} — in #{line.strip.inspect}" }
      end
    end
  end

  # ── Oracle B: the whole file ──────────────────────────────────────────────

  it "contains no backticked dotted token that is neither an emitted kind nor a real identifier" do
    tokens = doc.scan(/`([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)`/).flatten.uniq.sort
    expect(tokens.size).to be > 100, "the token scan collapsed (#{tokens.size}) — this oracle would be vacuous"

    unknown = tokens.reject { |t|
      next true if EMITTED.include?(t)
      next true if (ATTRIBUTE_REFS + SETTING_KEYS + ACTION_KINDS).include?(t)
      next true if WITHDRAWN_TOKENS.include?(t) # named BECAUSE it exists nowhere
      # A source-file reference, e.g. `sdwan_drift_sensor.rb`. Required to
      # exist, so a renamed file is a failure rather than a free pass.
      next Dir[File.join(ext_root, "**", t)].any? if t.end_with?(".rb", ".md", ".yaml", ".yml", ".go")

      # Otherwise it must appear as a STRING LITERAL in extension source. A
      # bare-code match would let `cert.expired` through on the strength of
      # `cert.expired?` — a method call on an unrelated object — which is how
      # a plausible-looking fabrication survives a weaker check.
      source.match?(/["'][^"'\n]*(?<![a-z0-9_.])#{Regexp.escape(t)}(?![a-z0-9_.?!])[^"'\n]*["']/)
    }

    expect(unknown).to eq([]),
      -> { "tokens in FLEET_SENSORS.md that name nothing in the codebase: #{unknown.inspect}" }
  end

  # ── Oracle C: the architecture diagram ────────────────────────────────────

  it "shows, in the diagram's Signals node, only namespaces that real kinds use" do
    # The node listed `instance.* / module.* / cert.* / config.* / gitops.* /
    # sdwan.* / honeypot.* / slo.* / project.* / storage.* / fleet.trading_*` —
    # ten matchable namespace globs, every one fabricated, ~180 lines above
    # any sensor block and therefore invisible to a heading-scoped guard.
    node = doc[/subgraph Signals\[.*?\]\s*\n(.*?)\n\s*end/m, 1] ||
           raise("could not locate the mermaid Signals subgraph — Oracle C would be vacuous")

    real_namespaces = EMITTED.map { |k| k.split(".").first }.uniq
    expect(real_namespaces).to eq([ "system" ])

    globbed = node.scan(/([a-z][a-z0-9_]*)\.\*/).flatten.uniq.sort
    expect(globbed).to eq(real_namespaces.sort),
      -> { "diagram advertises namespaces no kind uses: #{(globbed - real_namespaces).inspect}" }
  end

  # ── Oracle E: the emitted set is COMPLETE, not merely non-empty ───────────

  describe "the emitted-set derivation" do
    # Raised in review of this file: a literal scan cannot see a kind emitted
    # through a variable, and "zero literal hits" therefore never licenses
    # "nothing emits this". Every equality above rests on EMITTED being the
    # whole truth, so the completeness claim needs its own oracle rather than a
    # comment.
    #
    # Rather than DECLARE the blind spot, this closes it: every `kind:` in the
    # directory must fall into one of three resolvable cases. A fourth case —
    # an interpolated or computed kind — is what the parser genuinely cannot
    # see, and this example fails the moment one appears, naming the file, so
    # the parser is extended instead of quietly under-reporting.
    it "leaves no `kind:` argument the parser cannot resolve" do
      unresolved = Dir[File.join(ext_root, SENSORS_DIR, "*.rb")].flat_map { |path|
        src = File.read(path)
        src.to_enum(:scan, /\bkind:/).filter_map do
          off = Regexp.last_match.begin(0)
          line = src[(src.rindex("\n", off) || -1) + 1...(src.index("\n", off) || src.length)]
          arg  = src[off, 200].sub(/\Akind:\s*/, "")

          # (0) a COMMENT line. base_sensor.rb:9 documents the signal SHAPE
          #     with a placeholder (`kind: "system.<topic>"`) inside a `#`
          #     block. The main parser strips comments before building
          #     EMITTED, so a placeholder never reaches the emitted set — but
          #     this scan reads raw source, so without this clause it reports
          #     prose as an unresolvable emit. Skipping the line (not the
          #     placeholder shape) keeps the exclusion narrow: a real emit that
          #     happens to contain `<` is still caught.
          next if line.lstrip.start_with?("#")
          # (1) a CLOSED `system.` string literal — the ordinary emit. The
          #     closing quote is load-bearing: `arg.start_with?('"system.')`
          #     was the first version and it let
          #     `kind: "system.module_#{flavor}_drift"` through, which the main
          #     parser's own regex then failed to extract — a kind emitted and
          #     silently absent from EMITTED, with a sibling literal in the
          #     same file keeping the per-file non-vacuity check quiet. That is
          #     precisely the variable-emitter hole this example exists for,
          #     and it survived the example that was supposed to close it.
          next if arg.match?(/\A"system\.[a-z0-9_.]+"/)
          # (2) a SIGNAL_KIND-style constant, resolved above;
          next if arg.match?(/\A[A-Z][A-Z0-9_]*(SIGNAL|KIND)[A-Z0-9_]*\b/) || arg.match?(/\A[A-Z][A-Z0-9_]*\b/) && arg[/\A[A-Z][A-Z0-9_]*/].match?(/SIGNAL|KIND/)
          # (3) FORWARDING, which emits nothing on its own: a helper's own
          #     parameter list (`def signal(kind:, …)`, base_sensor.rb:36,
          #     boot_lkg_arm_sensor.rb:192, project_slo_sensor.rb:313) or a
          #     pass-through of that parameter (`kind: kind`). The literal each
          #     forwards is captured at the CALL site — boot_lkg at :114/:125,
          #     project_slo at :185/:203/:238/:261/:298 — so these contribute
          #     nothing and must not be read as unresolved;
          next if line.match?(/\bdef\s+\w*signal\w*\(/) || arg.match?(/\Akind\b/)
          # (4) a query, excluded from the emitted set by design;
          next if line.include?("where(")
          # (4b) a `kind:` belonging to an unrelated API. One exists:
          #      package_drift_sensor.rb:39 passes a PACKAGE REPOSITORY kind to
          #      `System::PackageAdapters.for`. Named by its call rather than
          #      waved through by shape, so a computed SIGNAL kind cannot hide
          #      behind the same "it's a method chain" reasoning.
          next if line.include?("PackageAdapters.for(")
          # (5) the ternary, whose arms are string literals on the next line.
          next if arg.match?(/\A[a-z_?.\s]+\?\s*\n?\s*"system\./m)

          "#{File.basename(path)}: #{arg.lines.first.to_s.strip}"
        end
      }

      expect(unresolved).to eq([]),
        -> { "kind: arguments the parser cannot resolve (EMITTED would be incomplete and every equality above vacuous on that side): #{unresolved.inspect}" }
    end

    it "reconciles against the DecisionEngine's bindings" do
      # INDEPENDENT oracle on the same completeness claim, from the consumer
      # side: a kind emitted through a shape the parser missed would show up
      # here as a binding with no emitter. The only two are the CVE sensors,
      # which live in cve_ops/sensors/ and are outside both this directory and
      # this document — the scope boundary, asserted rather than assumed.
      engine = File.read(File.join(ext_root, "server/app/services/system/fleet/decision_engine.rb"))
      bound = engine.scan(/^\s*"(system\.[a-z0-9_.]+)"\s*=>/).flatten.uniq
      expect(bound.size).to be > 40, "SIGNAL_BINDINGS scan collapsed — this oracle would be vacuous"

      expect(EMITTED - bound).to eq([]),
        -> { "emitted but bound to no action category: #{(EMITTED - bound).inspect}" }
      expect(bound - EMITTED).to eq([ "system.cve_critical_published", "system.module_critical_upgrade_ready" ])
    end
  end

  # ── Oracle D: the withdrawn kinds stay contained ──────────────────────────

  describe "the withdrawn signal kinds" do
    it "names none that a sensor actually emits" do
      # RATCHET. If a recovery counterpart is ever built, this reddens and
      # forces the doc to move that kind out of the withdrawal note and into a
      # `**Signals:**` declaration, rather than leaving it advertised as absent.
      expect(WITHDRAWN_TOKENS & EMITTED).to eq([])
    end

    it "appears nowhere in the file outside the correction note" do
      # CONTAINMENT, and the reason the correction note lists the fabrications
      # instead of deleting them: without this, "it is already in the withdrawn
      # list" becomes cover for re-introducing one into a sensor block.
      #
      # `system.runtime_docker_tls_rotate` is the documented exception — a
      # policy withdrawn by the 2026-05-19 audit, described in the seed-file
      # inventory far below the sensor blocks. Its own line must say it was
      # removed, so the exemption cannot be claimed by a bare mention.
      elsewhere = doc.sub(correction_note, "")
      offenders = WITHDRAWN_TOKENS.select { |t|
        elsewhere.match?(/(?<![a-z0-9_.])#{Regexp.escape(t)}(?![a-z0-9_.])/)
      }
      expect(offenders).to eq([ "system.runtime_docker_tls_rotate" ]),
        -> { "fabricated kinds mentioned outside the correction note: #{(offenders - [ 'system.runtime_docker_tls_rotate' ]).inspect}" }

      elsewhere.lines.grep(/system\.runtime_docker_tls_rotate/).each do |line|
        expect(line).to match(/was removed|no executor/),
          -> { "mentions the withdrawn policy without saying it was withdrawn: #{line.strip.inspect}" }
      end
    end

    it "covers every fabrication the correction note names" do
      # EQUALITY the other way: the note may not introduce a dotted token that
      # is neither an emitted kind nor a classified one. Without this the note
      # itself becomes an unguarded place to invent a name.
      named = correction_note.scan(/`([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)`/).flatten.uniq
      expect(named).not_to be_empty
      expect(named - EMITTED - WITHDRAWN_TOKENS - ATTRIBUTE_REFS - SETTING_KEYS -
             ACTION_KINDS - NON_SENSOR_KINDS).to eq([])
    end

    it "is actually listed in the note, every one of them" do
      # Found in review: the containment oracle above says where a withdrawn
      # kind may NOT appear, and the token-classification oracle says what the
      # note may not invent — but nothing said the note must still CONTAIN
      # them. The whole 12-row table could be deleted silently, which defeats
      # the stated reason for listing the fabrications instead of erasing them
      # (an operator who bound a policy to one has to be able to find it).
      missing = WITHDRAWN_TOKENS - correction_note.scan(/`([a-z][a-z0-9_.]+)`/).flatten -
                [ "system.runtime_docker_tls_rotate" ]
      expect(missing).to eq([]),
        -> { "withdrawn kinds no longer findable in the correction note: #{missing.inspect}" }
    end

    it "maps each fabrication to a real kind, not merely to some kind" do
      # Found in review: the oracles above check the note's token SET and never
      # the left-to-right PAIRING, so a row could send an operator repairing a
      # broken policy from `instance.silent` to `system.module_drift` and stay
      # green. Parse the table as pairs and check each side separately.
      rows = correction_note.lines.grep(/^>\s*\|/).reject { |l| l.match?(/^>\s*\|[\s:|-]+\|/) }
      rows = rows.reject { |l| l.match?(/Named in this doc|Actually emitted/) }
      expect(rows.size).to be >= 10, "the correction table collapsed — this oracle would be vacuous"

      rows.each do |row|
        left, right = row.sub(/^>\s*\|/, "").split("|", 2).map(&:to_s)
        from = left.scan(/`([a-z][a-z0-9_.]+)`/).flatten
        to   = right.scan(/`([a-z][a-z0-9_.]+)`/).flatten

        expect(from).not_to be_empty, -> { "correction row names nothing on the left: #{row.strip.inspect}" }
        expect(from - WITHDRAWN_TOKENS).to eq([]),
          -> { "left column is not a withdrawn name: #{(from - WITHDRAWN_TOKENS).inspect} in #{row.strip.inspect}" }
        expect(to).not_to be_empty, -> { "correction row names no replacement: #{row.strip.inspect}" }
        expect(to - EMITTED).to eq([]),
          -> { "right column points at a kind no sensor emits: #{(to - EMITTED).inspect} in #{row.strip.inspect}" }

        # Membership on each side is not enough — that was the first version of
        # this example, and it stayed GREEN when a row was rewritten to send
        # `instance.silent` to `system.module_drift`: both cells were
        # individually well-formed, and the row still misdirected an operator
        # repairing a broken policy. There is no pure name transform to check
        # against (`slo.violated` → `system.slo_violation`,
        # `sdwan.bgp_unhealthy` → `system.sdwan_bgp_session_unhealthy`), so the
        # oracle is STEM OVERLAP: every fabricated name must be paired with a
        # replacement it shares a word with.
        #
        # KNOWN LIMIT, stated rather than implied: this cannot separate two
        # kinds that share a stem (`system.sdwan_bgp_session_stale` swapped for
        # `system.sdwan_bgp_session_unhealthy` would pass). It kills the
        # unrelated-kind class, which is the one an edit actually produces.
        segs = ->(t) { t.split(/[._]/) - [ "system" ] }
        from.each do |f|
          expect(to.any? { |t| (segs.(f) & segs.(t)).any? }).to be(true),
            -> { "correction row pairs #{f} with an unrelated kind #{to.inspect}: #{row.strip.inspect}" }
        end
      end
    end
  end

  describe "the recovery-signal note" do
    # TRIPWIRE, not an oracle. The doc advertised detected/resolved PAIRS the
    # platform does not implement, so a reader waited for a resolution signal
    # that cannot come. The blocks were corrected rather than deleted, and say
    # so; these prove the withdrawal notice was not quietly dropped. They
    # cannot tell a correct explanation from a plausible one — Oracles A–C
    # carry the correctness claim.
    it "states that no sensor emits a recovery counterpart" do
      expect(doc).to match(/NOT IMPLEMENTED/)
    end

    it "attributes the withdrawal to the task that made it" do
      expect(doc).to include("IMP-e839dd0ffc05")
    end
  end
end
