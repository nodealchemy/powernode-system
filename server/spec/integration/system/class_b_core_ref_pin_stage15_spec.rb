# frozen_string_literal: true

require "rails_helper"

# IMP core-ref pin — the DISPATCH-TIME half of "which core did this artifact
# actually get built from".
#
# stage15.sh's Class-B arm used to clone the parent platform repo with a bare
# `git clone --depth 1 "$clone_url" /tmp/parent` — no ref — against a remote
# hardcoded to github.com/nodealchemy/powernode-platform, which is a MIRROR of
# the Gitea core is really pushed to and lags arbitrarily (three days on
# 2026-08-15; two outages). The build therefore baked whatever sat on the
# mirror's default branch, not the core commit the batch was dispatched
# against, and reported success either way.
#
# The fix pins the fetch to $CORE_REF, the batch's own recorded
# `expected_core_sha` — the SAME value System::CoreMirrorPreflight compares the
# mirror's HEAD against at dispatch and System::CoreProvenanceGate compares the
# published artifact's annotation against at promote. All three layers read one
# field, so they cannot disagree about what "the expected core" is.
#
# WHY A CONTENT SPEC. The pin lives in a shell script that only ever executes
# on a leased module-forge builder, inside a chroot, against a real remote —
# nothing in this suite can execute it. What CAN be checked here, cheaply and
# every run, is that the script still SAYS the things the pin depends on:
# an explicit ref on the fetch, an identity assertion on what came back, a
# failure message naming both the ref and the remote, and — the one that
# actually decays — NO unpinned clone anywhere on the pinned path. Rule 2 of
# the design is that the realistic regression is not someone deleting the pin,
# it is someone later adding a well-meaning `|| git clone --depth 1
# "$clone_url"` as "error handling", which would silently restore the exact
# defect. This spec is what fails when they do.
RSpec.describe "Class-B parent fetch is pinned to CORE_REF (stage15.sh)" do
  # extensions/system/server/spec/integration/system → extension root
  def extension_path(relative)
    File.expand_path("../../../../#{relative}", __dir__)
  end

  let(:stage15_path)  { extension_path("scripts/module-build/stage15.sh") }
  let(:forge_path)    { extension_path("modules/module-forge/rootfs/usr/local/bin/module-forge-build.sh") }
  let(:handler_path)  { extension_path("agent/internal/runtime/tasks/handlers/module_build.go") }

  let(:stage15) { File.read(stage15_path) }

  # The Class-B arm: everything between the `needs_parent` branch opening and
  # the end of the provenance capture that closes it. Scoped deliberately —
  # stage15.sh has other, unrelated `git clone` calls further down (the
  # tmux-manager arm clones a pinned third-party repo), and an assertion that
  # swept the whole file would either fail on those or have to special-case
  # them.
  let(:parent_arm) do
    start_idx = stage15.index(/^if \[ "\$needs_parent" = "1" \]; then$/)
    end_idx   = stage15.index("# --- END core-source provenance capture ---")
    raise "could not locate the needs_parent arm in stage15.sh" if start_idx.nil? || end_idx.nil?

    stage15[start_idx...end_idx]
  end

  # The arm with whole-line comments removed. Every assertion about what the
  # script DOES runs against this, because the arm deliberately talks at
  # length about the shapes it forbids ("do not add `|| git clone ...`") and a
  # scan that could not tell prose from code would fire on the warning itself
  # — the guard would then be satisfied by deleting its own explanation.
  def code_only(text)
    text.lines.reject { |l| l.lstrip.start_with?("#") }.join
  end

  let(:parent_arm_code) { code_only(parent_arm) }

  # ONLY the pinned branch, comments stripped. Every assertion about the pin
  # runs against THIS, not the whole arm — the arm also contains the legacy
  # unpinned clone and a pre-existing `rev-parse --verify HEAD` in the
  # provenance capture, either of which would satisfy a loosely-scoped
  # expectation with the pin deleted.
  let(:pinned_block) do
    block = parent_arm_code[/if \[ -n "\$core_ref" \]; then.*?(?=^\s*else$)/m]
    raise "could not locate the pinned branch of the Class-B arm" if block.nil?

    block
  end

  it "locates the Class-B parent arm" do
    expect(File).to exist(stage15_path)
    expect(parent_arm).to include("clone_url")
  end

  describe "the pinned fetch" do
    it "fetches an EXPLICIT ref rather than cloning the remote's default branch" do
      # `git clone --depth 1 --branch X` accepts a branch/tag NAME only and
      # REJECTS a raw sha, so --branch cannot express a sha pin at all. The
      # only form that fetches an arbitrary ref at depth 1 is
      # init + remote add + fetch <ref> + checkout --detach FETCH_HEAD.
      expect(pinned_block).to match(/git\s+(-C\s+\S+\s+)?fetch\s+--depth\s+1\s+origin\s+"\$core_ref"/),
                              "stage15.sh's Class-B arm does not fetch an explicit core ref — " \
                              "the parent tree is whatever the mirror's default branch points at"

      expect(pinned_block).to match(/git\s+(-C\s+\S+\s+)?checkout\s+--detach\s+FETCH_HEAD/),
                              "the fetched ref is never checked out — FETCH_HEAD must be made the worktree"
    end

    it "reads the ref from the CORE_REF environment variable" do
      # CORE_REF is the transport the whole chain agrees on: the platform sets
      # it in ci_build_context, the Go handler puts it in the build env, and
      # module-forge-build.sh exports it through the chroot.
      expect(parent_arm_code).to match(/core_ref="\$\{CORE_REF:-\}"/),
                                 "stage15.sh does not read CORE_REF — nothing the platform sends " \
                                 "can reach the fetch"
    end

    it "ASSERTS the resolved HEAD is the ref that was asked for" do
      # A name can resolve anywhere, which is exactly how this bug happened: a
      # correct branch name on a stale mirror. When the ref IS a full commit
      # identity, "the fetch succeeded" is not the same claim as "we are on
      # that commit" — verify it, or the pin is nominal.
      # Scoped to pinned_block on purpose: the provenance capture further down
      # the same arm has its OWN pre-existing `rev-parse --verify HEAD`, so a
      # whole-arm expectation here passes with the entire pin assertion deleted.
      expect(pinned_block).to match(/rev-parse\s+--verify\s+HEAD/),
                              "nothing in the PINNED branch resolves the post-fetch HEAD, " \
                              "so the pin is never verified"

      # Conditional on the ref actually being a commit identity — a name or an
      # abbreviation names more than one object, so there is nothing to assert.
      expect(pinned_block).to match(/\[0-9a-fA-F\]\{40\}/),
                              "no 40-hex test on the ref — the identity assertion cannot be " \
                              "conditional on the ref being a commit identity"

      # THE TEETH. The two expectations above only prove the SHAPE exists;
      # mutating the comparison to `if false; then` leaves both green. What
      # makes the pin real is that the resolved HEAD is compared against the
      # requested ref AND that a mismatch is fatal.
      comparison = pinned_block[/if\s+\[\s+"\$got_ref"\s+!=\s+"\$want_ref"\s+\];\s*then(.*?)fi/m, 1]
      expect(comparison).not_to be_nil,
                                "the pinned branch never compares the resolved HEAD against the " \
                                "requested ref — the fetch succeeding is NOT the same claim as " \
                                "standing on that commit"
      expect(comparison).to match(/\bdie\b/),
                            "a resolved-HEAD mismatch does not abort the build, so the pin is advisory"
      expect(pinned_block).to match(/want_ref=.*core_ref/m),
                              "the compared value is not derived from $core_ref"
    end

    it "names BOTH the ref and the remote when the fetch fails" do
      # The 2026-08-15 incident was a RIGHT ref on the WRONG host. A failure
      # that names only the ref reads as entirely plausible and sends the
      # operator looking in the wrong place.
      # Joined across backslash continuations first: the message legitimately
      # spans four lines, so a per-line check passes only as long as both
      # values happen to land on the same one — reflowing a correct message
      # would fail it.
      statements = parent_arm_code.gsub(/\\\n\s*/, " ").lines.select { |l| l =~ /\bdie\b|FATAL/ }
      expect(statements).not_to be_empty, "the Class-B arm has no failure path at all"

      naming_both = statements.any? do |stmt|
        stmt =~ /\$\{?core_ref\}?/ && stmt =~ /\$\{?(clone_remote|parent_host)\}?/
      end
      expect(naming_both).to be(true),
                             "no failure message names both the core ref and the remote it was sought " \
                             "on — right-ref-on-wrong-host is the actual incident shape"
    end
  end

  describe "no unpinned fallback (the regression that would silently restore the defect)" do
    it "has no `git clone` on the pinned path" do
      # `set -euo pipefail` is in force, so today the exposure is not a missing
      # check — it is someone later adding `|| git clone --depth 1
      # "$clone_url"` as error handling and quietly reinstating the bug.
      # Guard against the extraction silently truncating: pinned_block ends at
      # the first `else`, so an `else` added INSIDE the pinned branch would
      # narrow the region being scanned and quietly weaken this check.
      expect(pinned_block).to match(/checkout\s+--detach\s+FETCH_HEAD/),
                              "pinned_block was truncated before the checkout — the scan region is " \
                              "no longer the whole pinned branch"
      expect(pinned_block).not_to match(/git\s+clone/),
                                 "the pinned branch contains a `git clone` — a pinned fetch that can fall " \
                                 "back to an unpinned clone is not a pin"
    end

    it "never ORs a clone onto a failed fetch anywhere in the arm" do
      offenders = parent_arm_code.lines.each_with_index.select do |line, _i|
        line.include?("||") && line =~ /git\s+(clone|fetch)/
      end
      expect(offenders).to be_empty,
                           "a `||` arm on the parent fetch/clone is exactly the shape that turns " \
                           "'the mirror lags' back into 'silently ship stale core': " \
                           "#{offenders.map(&:first).map(&:strip).inspect}"
    end

    it "warns loudly when NO ref was supplied instead of pretending it is pinned" do
      # An absent CORE_REF is a real, non-fabricated state (a batch that could
      # not resolve a core tip; the legacy Gitea Actions path, which sends
      # none). It must still build — CoreProvenanceGate stays deliberately
      # inert there too — but it must never read as if it were pinned.
      unpinned_block = parent_arm[/if \[ -n "\$core_ref" \]; then.*?^\s*else$(.*)/m, 1]
      expect(unpinned_block).not_to be_nil, "could not locate the no-ref branch of the Class-B arm"
      expect(unpinned_block).to match(/UNPINNED/),
                                "the no-ref branch does not announce itself as UNPINNED"
    end
  end

  describe "the CORE_REF transport agrees end to end" do
    it "is placed in the build env by the agent's module-build handler" do
      go = File.read(handler_path)
      expect(go).to include(%(CoreRef)), "the Go ciBuildContext struct has no CoreRef field — " \
                                         "encoding/json DROPS unknown fields, so a core_ref the platform " \
                                         "sends would vanish silently"
      expect(go).to include(%("core_ref")), "CoreRef is not bound to the core_ref JSON key"
      expect(go).to match(/"CORE_REF="\s*\+\s*bctx\.CoreRef/),
                    "buildEnv does not emit CORE_REF — the handler maps a FIXED list of env vars, " \
                    "so an unmapped field never reaches module-forge-build.sh"
    end

    it "is forwarded through the chroot by module-forge-build.sh" do
      forge = File.read(forge_path)
      expect(forge).to match(/export CORE_REF=/),
                       "module-forge-build.sh does not export CORE_REF, so it cannot be inherited by " \
                       "stage15.sh inside the chroot"
    end
  end
end
