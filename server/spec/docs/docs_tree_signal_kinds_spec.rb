# frozen_string_literal: true

require "spec_helper"
require "set"
require_relative "../support/fleet_signal_kinds"

# IMP-e491c01f5c01 — signal-kind fabrication across the docs TREE.
#
# IMP-e839dd0ffc05 corrected docs/FLEET_SENSORS.md and guarded it with a
# FILE-scoped oracle. That guard reads exactly one file, so the identical
# fabrication standing in six SIBLING docs was neither corrected nor guarded:
# an operator following docs/ARCHITECTURE.md or docs/runbooks/node-provisioning.md
# wrote down a dead signal kind the day AFTER that fix shipped.
#
# WHY IT MATTERS: a stream filter, alert, or runbook grep keyed on a kind
# nothing emits matches nothing and reports NO error. `platform.recent_events`
# returns `success: true` with an empty list — the operator gets a
# successful-looking response and no signal that the kind does not exist.
#
# ─────────────────────────────────────────────────────────────────────────────
# SCOPE: THE WHOLE docs/ TREE — stated deliberately, per the task direction.
#
# A per-file guard repeats this problem for document eight, which is precisely
# how we got here: the file-scoped guard could not, by construction, see the
# six siblings. So both oracles below sweep `docs/**/*.md` — every file, no
# heading scoping, no per-document allowlist.
#
# WHAT I CONSIDERED AND REJECTED, so the next person does not re-litigate it:
#
#   * "every backticked `system.*` token must be an emitted kind" — REJECTED.
#     Measured: 176 legitimate tokens would fail. The `system.` prefix is
#     heavily overloaded across permission names (`system.modules.read`),
#     DecisionEngine action categories (`system.cert_rotate`), SiteSetting keys
#     (`system.sdwan.ovn.stall_after_seconds`), and non-sensor FleetEvent kinds
#     (`system.k3s.handshake.ready`). Making it green needs a ~176-entry
#     allowlist, which is a worse defect than the one it guards.
#
#   * "every token after emits/fires/raises must be emitted" — REJECTED, and
#     this one is a NEAR MISS worth explaining. It has ~13 unclassified tokens
#     today. They split three ways, and the split is the point:
#       - REAL, emitted outside this directory — `system.cve_critical_published`
#         (cve_ops/sensors/cve_published_sensor.rb), `federation.peer.rehandshaked`,
#         `platform.resilience.drain_started` (skill executors);
#       - REGEX ARTIFACTS — `system.sdwan_`, `system.disk_image_`, matched out of
#         prose like "emits `system.sdwan_*` signals";
#       - NO PRODUCER ANYWHERE, i.e. probably the same defect again —
#         `federation.peer.accepted` (only in a spec), `module.upgrade`,
#         `system.disk_image_regression_reported`, `system.cert.rotation_failed`.
#     Allowlisting all thirteen to reach green would LAUNDER that third group —
#     exactly the false-corroboration move this task was told to avoid. Widening
#     the emitted set to "any kind literal in extension source" shrinks the
#     unresolved list to those four plus the two artifacts, which is a tractable
#     follow-up; it is NOT done here because correcting them means expanding
#     into four more docs whose right answers I have not verified.
#
# The two oracles that survived are the ones with a bounded, verified
# false-positive surface: both are at ZERO after this task's corrections.
#
# ORACLES (equalities over the whole tree, never per-kind existence checks —
# a per-kind check cannot see a name someone invents later):
#
#   A. CONTAINMENT. No withdrawn kind appears anywhere under docs/ except
#      inside an explicitly MARKED correction region. Catches every syntax the
#      defect actually used: backticked prose, a mermaid arrow label, a JS
#      comment, and a copy-pasteable `kind: "..."` argument — none of which a
#      backtick-only or code-fence-only scan reads.
#   B. CLAIMS. Any dotted token a doc calls a "signal" must be one, backticked
#      or bare. Forward-looking: catches a BRAND-NEW invented name that is on
#      no withdrawn list. This is the oracle that found
#      SDWAN_MANAGER_AGENT.md:195,204 — two fabrications the task's own
#      enumeration missed, because that enumeration grepped only the seven
#      tokens it already believed in.
RSpec.describe "docs/ tree — signal kinds vs. the sensors that emit them" do
  ext_root = File.expand_path("../../..", __dir__)

  EMITTED_TREE = FleetSignalKinds.emitted(ext_root).freeze

  # A doc may legitimately NAME a withdrawn kind — to tell an operator who
  # bound a policy to it what became of it. That is allowed only inside an
  # explicitly marked region:
  #
  #   <!-- signal-kind-corrections:start -->
  #   … correction table / "this name matches nothing" warning …
  #   <!-- signal-kind-corrections:end -->
  #
  # An HTML-comment marker rather than a heading or a line-offset because the
  # heading-scoped variant of this guard has missed the same claim FOUR times
  # (a JSON appendix, a status table 400 lines away, a preamble 40 lines above,
  # a mermaid node 180 lines from any block). A marker is explicit, greppable,
  # and cannot drift as the document is edited around it.
  #
  # KNOWN LIMIT, stated rather than implied. This is an escape hatch, so it can
  # be abused: someone who wraps a LIVE fabrication in these markers, writes
  # "NOT IMPLEMENTED", and names any real kind alongside it will pass. Verified
  # by mutation — the cheap abuses (empty region, no NOT IMPLEMENTED, no real
  # replacement, markers deleted) are all caught; a deliberate well-formed
  # forgery is not. The guard is a ratchet against drift and copy-paste, not a
  # defence against an author determined to lie in the correction table itself.
  MARKER = /<!--\s*signal-kind-corrections:start\s*-->.*?<!--\s*signal-kind-corrections:end\s*-->/m

  # FLEET_SENSORS.md's correction note predates this convention and is bounded
  # by its own blockquote (IMP-e839dd0ffc05 guards its CONTENT in
  # fleet_sensors_signal_kinds_spec.rb — pairing, completeness, and the ratchet
  # that no withdrawn kind is secretly real). Named explicitly so the exemption
  # is one file, not a general amnesty for blockquotes.
  LEGACY_NOTE = { "docs/FLEET_SENSORS.md" => /^## Sensor Reference\n\n(?:^>.*\n)+/ }.freeze

  # One documented survivor, carried over from IMP-e839dd0ffc05: an intervention
  # POLICY (not a signal kind) withdrawn by the 2026-05-19 audit, named in the
  # seed-file inventory ~450 lines below the correction note. Its own line must
  # say it was withdrawn, so the exemption cannot be claimed by a bare mention.
  LEGACY_LINE_EXEMPTION = {
    "docs/FLEET_SENSORS.md" => { token: "system.runtime_docker_tls_rotate", must_match: /was removed|no executor/ }
  }.freeze

  # Real `FleetEvent` kinds that NO SENSOR emits, and so are legitimate targets
  # for a correction row even though they are absent from EMITTED_TREE.
  #
  # There is exactly one, and this example found it: `system.honeypot_triggered`
  # is written by `System::Honeypot::CanaryModuleService.observe_access!` and
  # READ by `honeypot_access_sensor`. The honeypot correction table has to point
  # at it, because that is the kind an operator queries with
  # `platform.recent_events` — the sensor's own `system.honeypot_access` is the
  # downstream escalation, a different thing.
  #
  # Asserted below to be a real string literal in source, so this list cannot
  # become a way to smuggle a fabricated name into a right-hand column.
  #
  # NAMED `TREE_` DELIBERATELY. RSpec defines these on Object, so a bare
  # `NON_SENSOR_KINDS` collided with the identically-named constant in
  # fleet_sensors_signal_kinds_spec.rb — ruby warned, and whichever file loaded
  # second silently clobbered the other. The two values agree TODAY, so the
  # collision was invisible in a green run; the day one of them changes it
  # becomes an order-dependent flake reproducing only when both files load.
  TREE_NON_SENSOR_KINDS = [ "system.honeypot_triggered" ].freeze

  let(:docs) do
    paths = Dir[File.join(ext_root, "docs/**/*.md")].sort
    raise "docs/ scan set is empty — every oracle here would be vacuous" if paths.size < 50

    paths.to_h { |p| [ p.sub("#{ext_root}/", ""), File.read(p) ] }
  end

  # Line numbers of every exempt line, per doc.
  #
  # Computed as an index set rather than by DELETING the regions from the text:
  # stripping first and scanning after renumbers everything below the cut, and
  # the first version of this file did exactly that — it reported
  # FLEET_SENSORS.md:516 for a line that is really at :555. A guard whose
  # failure message misdirects the reader to the wrong line is worse than no
  # line number at all.
  let(:exempt_lines) do
    docs.to_h do |rel, text|
      lines = text.lines
      exempt = []
      [ MARKER, LEGACY_NOTE[rel] ].compact.each do |pattern|
        text.to_enum(:scan, pattern).each do
          m = Regexp.last_match
          first = text[0...m.begin(0)].count("\n")
          # `chomp` before counting: LEGACY_NOTE ends in "\n", and counting that
          # terminator exempted one line PAST the note — found in review. Cheap
          # today (it was a blank line) but it silently widened the exemption to
          # whatever got added next.
          last = first + m[0].chomp.count("\n")
          exempt.concat((first..last).to_a)
        end
      end
      # The single documented line-level survivor.
      if (rule = LEGACY_LINE_EXEMPTION[rel])
        lines.each_with_index do |line, i|
          exempt << i if FleetSignalKinds.mentions?(line, rule[:token]) && line.match?(rule[:must_match])
        end
      end
      [ rel, exempt.to_set ]
    end
  end

  it "derives a non-trivial emitted set" do
    # Non-vacuity floor for BOTH oracles: an equality against an empty or
    # truncated set passes for the wrong reason.
    expect(EMITTED_TREE.size).to be >= 40
    expect(EMITTED_TREE).to all(start_with("system."))
    expect(FleetSignalKinds::WITHDRAWN.size).to be >= 25
  end

  it "keeps the withdrawn list disjoint from what the sensors emit" do
    # RATCHET, inherited from IMP-e839dd0ffc05. If a withdrawn kind is ever
    # actually built, this reddens and forces it out of the withdrawn list
    # rather than leaving the tree guarded against a name that now works.
    expect(FleetSignalKinds::WITHDRAWN & EMITTED_TREE).to eq([])
  end

  # ── Oracle A: containment, tree-wide ──────────────────────────────────────

  it "names no withdrawn signal kind outside a marked correction region" do
    offenders = docs.flat_map { |rel, text|
      text.lines.each_with_index.flat_map { |line, i|
        next [] if exempt_lines[rel].include?(i)

        FleetSignalKinds::WITHDRAWN.filter_map { |token|
          "#{rel}:#{i + 1} names `#{token}`" if FleetSignalKinds.mentions?(line, token)
        }
      }
    }

    expect(offenders).to eq([]), lambda {
      "docs naming a signal kind no sensor emits (operators act on these):\n" +
        offenders.map { |o| "  #{o}" }.join("\n")
    }
  end

  it "still contains the marked correction regions it claims to exempt" do
    # The exemption must not become a way to DELETE the corrections: without
    # this, stripping every marked region (or the whole table inside one) is
    # silently green, and an operator who bound a policy to a withdrawn name
    # loses the only record of what replaced it.
    marked = docs.select { |_, text| text.match?(MARKER) }.keys
    expect(marked).not_to be_empty, "no doc carries a signal-kind correction region any more"

    # EVERY region, not just the first. `docs[rel][MARKER]` returns String#[]'s
    # FIRST match, so a second region in the same file — empty, or with no
    # replacement, or with no NOT IMPLEMENTED — was never validated while its
    # withdrawn names were still exempt from Oracle A. Found in review; it made
    # this example's own comment false.
    marked.each do |rel|
      regions = docs[rel].scan(MARKER)
      expect(regions).not_to be_empty

      regions.each_with_index do |region, idx|
        where = "#{rel} correction region ##{idx + 1}"

        named = FleetSignalKinds::WITHDRAWN.select { |t| FleetSignalKinds.mentions?(region, t) }
        expect(named).not_to be_empty,
          -> { "#{where} is EMPTY — the withdrawn names it documented are gone" }

        expect(region).to match(/NOT IMPLEMENTED/),
          -> { "#{where} no longer marks the names as NOT IMPLEMENTED" }

        real = region.scan(/`(system\.[a-z0-9_.]+)`/).flatten & EMITTED_TREE
        expect(real).not_to be_empty, -> { "#{where} names no real replacement kind" }

        # A region may not swallow the document. Whole-file wrapping passes
        # every check above while exempting 100% of the lines — a total amnesty
        # dressed as a correction note. Bounded by BOTH a line cap and a share
        # of the file so neither a huge doc nor a tiny one slips through.
        region_lines = region.count("\n") + 1
        file_lines   = docs[rel].count("\n") + 1
        expect(region_lines).to be <= 45,
          -> { "#{where} spans #{region_lines} lines — too large to be a correction note" }
        expect(region_lines.to_f / file_lines).to be <= 0.35,
          -> { "#{where} covers #{(100.0 * region_lines / file_lines).round}% of the file" }
      end
    end
  end

  it "pairs each fabricated name with a plausibly-related replacement" do
    # Ported from fleet_sensors_signal_kinds_spec.rb. Without it, the oracles
    # above check only the SET of tokens in a region and never the left→right
    # PAIRING, so a table row could send an operator repairing a broken policy
    # from `instance.silent` to `system.module_drift` and stay green — the
    # sibling spec's comment records that exact regression. Re-introducing the
    # membership-only version here would have re-opened it for the four new
    # tables.
    #
    # There is no pure name transform to check against (`slo.violated` →
    # `system.slo_violation`, `sdwan.bgp_unhealthy` →
    # `system.sdwan_bgp_session_unhealthy`), so the oracle is STEM OVERLAP:
    # every fabricated name must be paired with a replacement sharing a word.
    #
    # KNOWN LIMIT, same as the sibling's: it cannot separate two kinds that
    # share a stem. It kills the unrelated-kind class, which is what a careless
    # edit actually produces.
    segs = ->(t) { t.split(/[._]/) - [ "system" ] }
    checked = 0

    docs.each do |rel, text|
      text.scan(MARKER).each do |region|
        region.lines.grep(/\|/).reject { |l| l.match?(/\|[\s:|-]+\|$/) }.each do |row|
          left, right = row.split("|", 3).values_at(1, 2).map(&:to_s)
          from = left.to_s.scan(/`([a-z][a-z0-9_.]+)`/).flatten & FleetSignalKinds::WITHDRAWN
          next if from.empty?

          to = right.to_s.scan(/`([a-z][a-z0-9_.]+)`/).flatten
          checked += 1

          expect(to - EMITTED_TREE - TREE_NON_SENSOR_KINDS).to eq([]),
            -> { "#{rel}: correction row points at a kind nothing emits: #{(to - EMITTED_TREE - TREE_NON_SENSOR_KINDS).inspect} in #{row.strip.inspect}" }
          from.each do |f|
            expect(to.any? { |t| (segs.(f) & segs.(t)).any? }).to be(true),
              -> { "#{rel}: correction row pairs #{f} with an unrelated kind #{to.inspect}: #{row.strip.inspect}" }
          end
        end
      end
    end

    expect(checked).to be >= 8, "only #{checked} correction rows parsed — this oracle would be near-vacuous"

    # TREE_NON_SENSOR_KINDS is the one classification that could launder a
    # fabrication into a right-hand column, so it is held to its own
    # definition: real in source, and genuinely not sensor-emitted.
    source = Dir[File.join(ext_root, "server/app/**/*.rb")]
               .reject { |p| File.basename(p).start_with?("example_") }
               .map { |p| File.read(p) }.join("\n")
    expect(TREE_NON_SENSOR_KINDS & EMITTED_TREE).to eq([])
    TREE_NON_SENSOR_KINDS.each do |k|
      expect(source).to include(%("#{k}")),
        -> { "#{k} is classified as a real non-sensor kind but appears in no source string" }
    end
  end

  # ── Oracle B: "X signal" claims, tree-wide ────────────────────────────────

  it "calls nothing a signal that no sensor emits" do
    # Backtick OPTIONAL. The three fabrications this found in
    # SDWAN_MANAGER_AGENT.md sit in mermaid arrow labels
    # (`SV->>DE: sdwan.vip_holder_silent signal`) where nothing is backticked —
    # a backtick-only scan reads straight past them, which is why the earlier
    # enumeration missed two of the three.
    claims = docs.flat_map { |rel, text|
      text.lines.each_with_index.flat_map { |line, i|
        next [] if exempt_lines[rel].include?(i)

        line.scan(/`?\b([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)`?\s+signals?\b/).flatten
            .reject { |t| EMITTED_TREE.include?(t) }
            .map { |t| "#{rel}:#{i + 1} calls `#{t}` a signal" }
      }
    }

    expect(claims).to eq([]), lambda {
      "tokens a doc calls a signal but that no sensor emits:\n" +
        claims.map { |c| "  #{c}" }.join("\n")
    }
  end
end
