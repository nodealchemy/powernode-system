# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

# IMP-01a0e40a-c0ef / IMP-094d900f9093 part 2 — rails-relock-gemfile.sh
# re-locks Gemfile.lock for THIS NODE's actual extension composition. It
# used to be inlined in rails-setup.sh (see that script's git history for
# the original incident and the two review rounds that hardened it); this
# spec was moved out of rails_setup_root_prep_spec.rb along with the code
# when it became a standalone script callable from two places (rails-
# setup.sh's own boot sweep, and rails.service's own `ExecStartPre=+` —
# see the manifest and rails-setup.sh's own header comment for why the
# second caller exists).
#
# HONEST LIMITS OF THIS SPEC (carried over from rails_setup_root_prep_
# spec.rb's own header, and still true here): most of the fine-grained
# examples below are structural/content-level assertions on source text,
# not a sandboxed root+bundler harness exercising the real script end to
# end. The "actually run" describe block below is the exception — it
# genuinely executes the extracted function bodies via `bash -c` against
# stub bundlers, proving the isolation/atomic-replace/non-fatal behavior
# by running it, not by reading the source for the right words.
RSpec.describe "rails-relock-gemfile.sh (IMP-01a0e40a-c0ef, IMP-094d900f9093 part 2)" do
  let(:extension_root) { File.expand_path("../../..", __dir__) }
  let(:script_path) do
    File.join(extension_root, "modules/powernode-hub-backend/rootfs/usr/local/bin/rails-relock-gemfile.sh")
  end
  let(:script) { File.read(script_path) }

  # The header comment's own prose documents "bundle install", "bundle lock
  # --local", and (in path_gems_in_lock's docstring) "exit 1" as things it
  # explains or forbids -- so index/regex assertions about the actual
  # CODE's behavior must not be fooled by those words appearing first, or
  # at all, in the comments. Strip comment-only lines before making any
  # claim about what the code does.
  let(:code_lines) do
    script.lines.reject { |line| line.strip.start_with?("#") }.join
  end

  it "exists and is syntactically valid bash" do
    expect(File.exist?(script_path)).to be(true)
    _out, err, status = Open3.capture3("bash", "-n", script_path)
    expect(status.success?).to be(true), "bash -n failed: #{err}"
  end

  it "is committed executable (100755) -- exec'd directly by rails-setup.sh and by rails.service's ExecStartPre=+" do
    out, _err, status = Open3.capture3("git", "-C", extension_root, "ls-files", "-s", "--",
                                        "modules/powernode-hub-backend/rootfs/usr/local/bin/rails-relock-gemfile.sh")
    expect(status.success?).to be(true)
    mode = out.split(/\s+/).first
    expect(mode).to eq("100755"),
      "committed #{mode.inspect} but exec'd directly (no interpreter prefix) by both callers -- a build that " \
      "preserves modes (rsync -a, no chmod step) would ship it non-executable and both callers fail 203/EXEC"
  end

  it "does NOT reuse this node's REAL bundler config/path -- that was the HIGH finding (review round)" do
    expect(code_lines).not_to match(/BUNDLE_APP_CONFIG="\$BUNDLE_CONFIG_DIR"/),
      "pointing root's bundle resolve at rails-owned $BUNDLE_CONFIG_DIR/$BUNDLE_STATE_DIR lets a " \
      "compromised rails plant a gemspec root then evaluates as Ruby -- see this file's SECURITY comment"
    expect(code_lines).not_to match(/BUNDLE_PATH="\$BUNDLE_STATE_DIR"/)
  end

  it "isolates BUNDLE_APP_CONFIG, HOME and TMPDIR under a scratch dir, as local -x" do
    %w[BUNDLE_APP_CONFIG HOME TMPDIR].each do |var|
      expect(code_lines).to match(/local -x #{var}="\$scratch\//),
        "#{var} must be `local -x` under $scratch -- exported for this function only, never leaked to the " \
        "rest of the script, and never under a rails-writable path"
    end
  end

  it "does NOT isolate BUNDLE_PATH under scratch (review round, S4) -- setting it there breaks gem visibility" do
    expect(code_lines).not_to match(/local -x BUNDLE_PATH=/),
      "BUNDLE_PATH pointed at an empty scratch dir makes Bundler treat that as the definitive installed-gems " \
      "location and ignore GEM_HOME/GEM_PATH entirely -- verified live this makes even a stub-registered gem " \
      "read as \"not found\". `bundle lock` never installs anything, so it never needs a real BUNDLE_PATH."
  end

  it "runs the resolve as $RAILS_USER via runuser, not root (review round, S3)" do
    expect(code_lines).to match(/runuser -u "\$RAILS_USER" -- env/),
      "the actual `bundle lock` call must run as the unprivileged rails user -- root creating/chowning scratch " \
      "state and doing the final compare+swap is fine; root evaluating a gemspec is exactly what this isolation " \
      "exists to prevent"
  end

  it "stub-registers vendor/cache's gems by gemspec only, in ONE root Ruby process, not $RAILS_USER and not one process per gem (review round R4, PERFORMANCE + SECURITY)" do
    expect(code_lines).to match(/Gem::Package\.new\(f\)\.spec/),
      "a single Ruby process reading every Gem::Package directly is the fix for the old one-runuser-per-gem " \
      "loop measured at 1m25s over 325 real .gem files (critic, review round R4) -- verified live here at ~3s"
    expect(code_lines).not_to match(/runuser -u "\$RAILS_USER" -- gem spec/),
      "the OLD per-gem shape ran `gem spec` once per cached .gem via runuser -- replaced entirely by " \
      "build_gem_stubs's single batched Ruby process"
    expect(code_lines).not_to match(/gem install/),
      "a real `gem install` from vendor/cache would compile native extensions on EVERY rails start (caller 2) " \
      "-- only the gemspec is needed for bundle lock's resolution, never the installed content"
  end

  it "builds the vendor/cache stubs as ROOT, in a root-owned 0755 dir, never chowned to $RAILS_USER (review round R4, SECURITY)" do
    expect(code_lines).to match(/chmod 0755 "\$gem_stub_dir"/),
      "the previous shape ran `runuser -u \$RAILS_USER -- gem spec FILE --ruby > \"\$stub_path\"`, opening the " \
      "write INSIDE a directory already chowned to \$RAILS_USER -- a rails-planted symlink there would make " \
      "root's own redirect follow it and truncate an arbitrary file. root now owns this directory throughout " \
      "and writes every stub itself; only the resolve (attempt_bundle_lock) ever runs as \$RAILS_USER against it"
    expect(code_lines).not_to match(/chown[^\n]*gem_stub_dir/),
      "the stub dir must never be chowned to $RAILS_USER -- only $scratch (the bundle-config/HOME/TMPDIR tree) is"
  end

  it "the stub fallback's GEM_PATH is the stub dir ALONE, never the real ambient Gem.path (review round R4, CORRECTNESS -- this reverses the prior fix)" do
    expect(code_lines).to match(/GEM_PATH="\$gem_home"/),
      "a critic reproduced a dependency resolvable from this machine's real, ambient Gem.path but genuinely " \
      "ABSENT from vendor/cache -- appending the real path let the fallback pin it into Gemfile.lock anyway, " \
      "and a REAL frozen `bundle install --local` (vendor/cache only, exactly what rails does at boot) then " \
      "failed. The fallback must only ever see the stub dir, so anything it resolves is guaranteed to also be " \
      "installable from vendor/cache alone."
    expect(code_lines).not_to match(/GEM_PATH="\$gem_stub_dir:\$real_gem_path"/),
      "the OLD (now-reverted) shape appended the real Gem.path -- this is exactly the correctness bug R4 fixed"
  end

  it "pins the lock's own BUNDLED WITH line to the ACTUALLY running bundler after every resolve (review round R4, follow-up to the GEM_PATH fix)" do
    expect(code_lines).to match(/pin_bundled_with "\$tmp_lockfile"/),
      "narrowing GEM_PATH to the stub dir alone (previous test) means bundler itself is no longer resolvable " \
      "there either, and Bundler.bundler_version_to_lock silently falls back to Ruby's bundled DEFAULT bundler " \
      "gem instead of the one actually running -- verified live this happens even with `bundle lock " \
      "--bundler=<version>` passed explicitly. Rewriting the line afterward, deterministically, avoids " \
      "reintroducing the real Gem.path just to keep this one line honest."
    pin_idx  = code_lines.index('pin_bundled_with "$tmp_lockfile"')
    cmp_idx  = code_lines.index('cmp -s "$tmp_lockfile" "$RAILS_DIR/Gemfile.lock"')
    expect(pin_idx).not_to be_nil
    expect(cmp_idx).not_to be_nil
    expect(pin_idx).to be < cmp_idx,
      "the pin must happen BEFORE the cmp -s comparison, or a version-only drift would look like a real " \
      "content change (or vice versa) on every single boot"
  end

  it "resolves the running bundler's own gem dir + gemspec ONCE, as root, before any isolation (review round R5, HIGH #1)" do
    expect(code_lines).to match(/Gem::Specification\.find_by_name\("bundler", ENV\["BUNDLER_VERSION"\]\)/),
      "must resolve from the AMBIENT (unisolated) environment, using the version this script itself is " \
      "actually running under -- not a hardcoded version, and not resolved from inside an isolated GEM_HOME " \
      "(which is exactly the chicken-and-egg problem this closes)"
    expect(code_lines).to match(/spec\.full_gem_path/)
    expect(code_lines).to match(/spec\.loaded_from/)
    resolve_idx = code_lines.index('Gem::Specification.find_by_name("bundler", ENV["BUNDLER_VERSION"])')
    fast_idx    = code_lines.index('bundler_only_home="$(TMPDIR=/tmp mktemp -d)"')
    expect(resolve_idx).not_to be_nil
    expect(fast_idx).not_to be_nil
    expect(resolve_idx).to be < fast_idx, "bundler's real location must be resolved BEFORE the first isolated home is even created"
  end

  it "build_isolated_gem_home symlinks the real bundler gem dir and copies its gemspec, tolerating an unresolved bundler location (review round R5)" do
    expect(code_lines).to match(/ln -sfn "\$BUNDLER_GEM_DIR" "\$dir\/gems\//),
      "a SYMLINK, not a copy -- bundler's own lib tree is sizeable, and this directory gets rm -rf'd on every call"
    expect(code_lines).to match(/cp "\$BUNDLER_GEMSPEC" "\$dir\/specifications\/"/)
    expect(code_lines).to match(/-n "\$\{BUNDLER_GEM_DIR:-\}" && -n "\$\{BUNDLER_GEMSPEC:-\}"/),
      "must tolerate BUNDLER_GEM_DIR/BUNDLER_GEMSPEC never having resolved -- the resolve this feeds then fails " \
      "loudly on its own (\"can't find gem bundler\"), which is correct; this function must not error first"
  end

  it "an empty BUNDLER_VERSION omits --bundler= from the lock call, the same way pin_bundled_with already guards it (review round R5, item 4)" do
    expect(code_lines).to match(/if \[\[ -n "\$BUNDLER_VERSION" \]\]; then\s*\n\s*lock_args\+=\(--bundler="\$BUNDLER_VERSION"\)/),
      "a literal `--bundler=` (empty value) is a real, invalid requested version to bundler, not \"no " \
      "preference\" -- must be omitted entirely when BUNDLER_VERSION could not be determined"
  end

  it "computing BUNDLER_VERSION is itself bounded by `timeout 15` (review round R5, Critic-1 nit)" do
    expect(code_lines).to match(/timeout 15 "\$BUNDLE_BIN" --version/),
      "caller 1 (rails-setup.sh) is a oneshot unit with no StartTimeoutSec of its own -- a wedged BUNDLE_BIN " \
      "must not hang boot forever just to learn its own version"
  end

  it "marks native-extension gems as already built in the stub GEM_HOME, so they are not dropped from the index (review round R4, nit)" do
    expect(code_lines).to match(/gem\.build_complete/),
      "RubyGems' own installed-gem machinery uses this marker to consider a gem's extensions already built"
    expect(code_lines).to match(/Gem::Platform\.local/)
    expect(code_lines).to match(/Gem\.extension_api_version/)
  end

  it "drops `bundle check` entirely (review round) -- it hit the same rails-owned-path escalation as the old lock step" do
    expect(code_lines).not_to match(/bundle\s+check\b/)
  end

  it "locks with --local only -- no network, and never a full bundle install" do
    expect(code_lines).to match(/bundle lock --local/)
    expect(code_lines).not_to match(/bundle\s+install/),
      "a full `bundle install` compiles native extensions and can fill the small root overlay -- only " \
      "`bundle lock --local` belongs here"
  end

  it "resolves into a TEMP lockfile, compares, then swaps in a SECOND fresh root-owned temp file (mv -f), never writing bundler straight to the real lock" do
    expect(code_lines).to match(/mktemp "\$RAILS_DIR\/Gemfile\.lock\.relock\.XXXXXX"/)
    expect(code_lines).to match(/--lockfile="\$lockfile"/),
      "the shared attempt_bundle_lock helper takes the lockfile path as an argument now (review round R4)"
    expect(code_lines).to match(/cmp -s "\$tmp_lockfile" "\$RAILS_DIR\/Gemfile\.lock"/)
    expect(code_lines).to match(/mktemp "\$RAILS_DIR\/Gemfile\.lock\.relock-final\.XXXXXX"/),
      "review round R4, nit: the swap must go through a FRESH, root-created temp file, never the rails-touched " \
      "$tmp_lockfile inode directly -- that inode has been written to by the runuser'd bundler process throughout"
    expect(code_lines).to match(/cp "\$tmp_lockfile" "\$final_tmp"/)
    expect(code_lines).to match(/mv -f "\$final_tmp" "\$RAILS_DIR\/Gemfile\.lock"/)
    expect(code_lines).not_to match(/mv -f "\$tmp_lockfile" "\$RAILS_DIR\/Gemfile\.lock"/),
      "the OLD shape moved the rails-touched temp file straight into place -- R4 inserts final_tmp instead"
  end

  it "seeds the temp lockfile from the CURRENT lock (cp -p) BEFORE resolving -- second review round, HIGH #2" do
    expect(code_lines).to match(/cp -p "\$RAILS_DIR\/Gemfile\.lock" "\$tmp_lockfile"/),
      "resolving `--lockfile=` against an EMPTY temp file (mktemp's default) makes bundler fail outright or " \
      "re-resolve from scratch against the isolated, empty BUNDLE_PATH -- it must be seeded with the CURRENT " \
      "lock's content first"
    seed_idx = code_lines.index('cp -p "$RAILS_DIR/Gemfile.lock" "$tmp_lockfile"')
    lock_idx = code_lines.index("bundle lock --local")
    expect(seed_idx).not_to be_nil
    expect(lock_idx).not_to be_nil
    expect(seed_idx).to be < lock_idx, "must seed the temp lockfile before calling bundle lock, not after"
  end

  it "matches the ORIGINAL lockfile's mode and owner before the swap -- second review round, HIGH #1 (now against $final_tmp, review round R4)" do
    expect(code_lines).to match(/chmod --reference="\$RAILS_DIR\/Gemfile\.lock" "\$final_tmp"/),
      "mktemp creates the temp file 0600; mv installs it with whatever mode it already had -- rails no longer " \
      "reads the real lockfile via any inherited capability (capabilities:[]), and powernode-rails-exec (no " \
      "elevated capabilities at all) already cannot read a 0600 root-owned file at all"
    expect(code_lines).to match(/chmod 0644 "\$final_tmp"/), "a literal fallback if --reference can't read the original"
    expect(code_lines).to match(/chown --reference="\$RAILS_DIR\/Gemfile\.lock" "\$final_tmp"/)

    reference_idx = code_lines.index('chmod --reference="$RAILS_DIR/Gemfile.lock" "$final_tmp"')
    mv_idx        = code_lines.index('mv -f "$final_tmp" "$RAILS_DIR/Gemfile.lock"')
    expect(reference_idx).not_to be_nil
    expect(mv_idx).not_to be_nil
    expect(reference_idx).to be < mv_idx, "mode/owner must be fixed BEFORE the swap, not after"
  end

  it "a failed mv does not log \"re-locked\" -- checks mv's own exit status (nit)" do
    expect(code_lines).to match(/if ! mv -f "\$final_tmp" "\$RAILS_DIR\/Gemfile\.lock"; then/)
    mv_check_idx     = code_lines.index('if ! mv -f "$final_tmp" "$RAILS_DIR/Gemfile.lock"; then')
    relocked_log_idx = code_lines.index("re-locked Gemfile.lock")
    expect(mv_check_idx).not_to be_nil
    expect(relocked_log_idx).not_to be_nil
    expect(mv_check_idx).to be < relocked_log_idx, "the mv guard must wrap the success log, not follow it unconditionally"
  end

  it "wraps the ENTIRE resolve (fast path AND, if needed, the stub fallback) in ONE `timeout -k 10 120` (review round R4, item 1c)" do
    expect(code_lines).to match(/timeout -k 10 120 bash -c '/),
      "the previous shape bounded only the final bundle-lock call -- caller 2 runs this on EVERY rails start, " \
      "and R4 added a potentially-slow stub-build step in between, so the WHOLE sequence (fast attempt, stub " \
      "build, retry) must share one bound, not three separately-timed calls whose SUM could exceed it"
    expect(code_lines).not_to match(/timeout -k 10 120 runuser -u "\$RAILS_USER" -- env/),
      "the OLD shape bounded only the runuser'd bundle call directly -- replaced by the single bash -c wrapper"
    expect(code_lines).to match(/attempt_bundle_lock "\$tmp_lockfile" "\$bundler_only_home"/),
      "the fast attempt, inside the timeout -- review round R5: no longer an empty gem_home, see the " \
      "bundler-isolation test below for why"
    expect(code_lines).to match(/attempt_bundle_lock "\$tmp_lockfile" "\$gem_stub_dir"/), "the stub retry, inside the same timeout"
  end

  it "the fast path runs FIRST, against a bundler-isolated (not stub-cache) home, and only builds vendor/cache stubs on failure (review round R4 item 1a + R5 item HIGH#1, PERFORMANCE)" do
    fast_idx  = code_lines.index('attempt_bundle_lock "$tmp_lockfile" "$bundler_only_home"')
    fail_idx  = code_lines.index("fast path resolve failed")
    build_idx = code_lines.index('build_gem_stubs "$gem_stub_dir"')
    retry_idx = code_lines.index('attempt_bundle_lock "$tmp_lockfile" "$gem_stub_dir"')
    [ fast_idx, fail_idx, build_idx, retry_idx ].each { |i| expect(i).not_to be_nil }
    expect(fast_idx).to be < fail_idx
    expect(fail_idx).to be < build_idx
    expect(build_idx).to be < retry_idx
  end

  it "BOTH the fast path and the fallback build an isolated gem home that makes bundler itself visible (review round R5, HIGH #1)" do
    expect(code_lines).to match(/bundler_only_home="\$\(TMPDIR=\/tmp mktemp -d\)"/),
      "the fast path is no longer \"no override at all\" (review round R4's own shape) -- on this module's real " \
      "runtime-ruby layout, bundler 2.7.1 is a REGULAR gem (stage15.sh installs it explicitly), not a Ruby " \
      "default gem, so an isolated resolve that can't see it either silently runs the WRONG (default 2.4.19) " \
      "bundler or fails outright once that bundler notices the locked BUNDLED WITH and tries to re-exec exactly " \
      "2.7.1 (Gem::GemNotFoundException) -- reproduced live against this module's actual gem layout"
    expect(code_lines).to match(/build_isolated_gem_home "\$bundler_only_home"/)
    expect(code_lines).to match(/build_isolated_gem_home "\$gem_stub_dir"/),
      "the fallback's stub dir must ALSO get bundler registered into it, not just the fast path's dedicated home"
  end

  it "isolated gem homes are created under the REAL /tmp (sticky bit), never the inherited (rails-owned) scratch TMPDIR (review round R5, SECURITY item 3)" do
    expect(code_lines).to match(/TMPDIR=\/tmp mktemp -d/),
      "bare `mktemp -d` inside the timeout-wrapped child would honor the INHERITED TMPDIR ($scratch/tmp, " \
      "already chowned to $RAILS_USER) -- a $RAILS_USER process could rename that dir away and plant a symlink " \
      "in its place between mktemp and root's own writes into it, and root would then write through the " \
      "symlink. /tmp's sticky bit stops a non-owning, non-root process from renaming/unlinking mktemp's own " \
      "(unpredictably-named, atomically-created) entry there regardless of that entry's own mode."
    expect(code_lines).not_to match(/gem_stub_dir="\$\(mktemp -d\)"/),
      "the OLD (R4) shape used bare mktemp -d here, silently inheriting the rails-owned scratch TMPDIR"
  end

  it "cleans up its scratch dir and BOTH temp lockfiles on every return, via a RETURN trap that is never disarmed (review round R4)" do
    expect(code_lines).to match(/trap 'rm -rf "\$scratch"; rm -f "\$tmp_lockfile" "\$\{final_tmp:-\}"' RETURN/),
      "final_tmp is unset on most return paths (${final_tmp:-} avoids an unbound-variable reference); both " \
      "rm -f targets are no-ops once final_tmp has already been mv'd away on the success path"
    expect(code_lines).not_to match(/trap - RETURN/),
      "review round R4: tmp_lockfile is no longer consumed by the final mv (final_tmp is, see the swap test " \
      "above), so disarming this trap on the success path (the OLD shape's own last two lines) would leak " \
      "tmp_lockfile forever on every actual re-lock -- reproduced live before this fix, fixed by always letting " \
      "the trap fire instead of manually rm -rf'ing $scratch and then disarming it"
  end

  it "is loud but non-fatal: a lock failure warns and the SCRIPT's own exit code is still 0" do
    expect(code_lines).to match(/echo.*WARNING.*bundle lock --local failed/i)
    expect(code_lines).not_to match(/\bexit\s+[1-9]/), "must degrade, not abort"
    expect(code_lines).to match(/relock_gemfile_for_this_node \|\| true\s*\z/),
      "the top-level invocation must tolerate a nonzero return under this script's own set -e, so a failure " \
      "here never cancels caller 2's ExecStartPre= (which would cancel rails' own start job)"
  end

  it "documents the two closed blockers (IMP-094d900f9093 part 2), not just the manifest capabilities change" do
    expect(script).to match(/REVERSED, IMP-094d900f9093 part 2/)
    expect(script).to match(/BUNDLE_FROZEN=1/),
      "blocker (a): rails-start.sh's first-boot bundle install must be documented as fixed via BUNDLE_FROZEN"
    expect(script).to match(/FileUtils\.touch/),
      "the mechanism (bundler's write_lock touching mtime even on identical content) must be documented, not just asserted fixed"
    expect(script).to match(/rails\.service's own ExecStartPre=-\+/),
      "blocker (b): a live module refresh restarting only rails must be documented as fixed via caller 2 (ExecStartPre=+)"
    expect(script).to match(/writeDependencyDirectives/),
      "blocker (b)'s original problem statement must still cite where it was checked in the agent, not asserted"
    expect(script).to match(/units\.go, Action/)
  end

  it "documents caller 2's own privilege-exemption mechanism (the `+` prefix), citing systemd's own semantics" do
    expect(script).to match(/systemd\.service\(5\)/)
    expect(script).to match(/full privileges/)
  end

  it "is honest that a failed re-lock against a genuinely stale lock CAN crash-loop rails, and names the manual recovery (review round)" do
    expect(script).to match(/a real crash loop, not a\s*\n#\s*hypothetical one/),
      "the old claim that an un-re-locked lock is merely stale, never a crash loop, stopped being " \
      "true under BUNDLE_FROZEN=1 + capabilities:[] and must not still read that way"
    expect(script).to match(/RECOVERY, when that happens/)
    expect(script).to match(/CapabilityBoundingSet=CAP_CHOWN CAP_FOWNER CAP_DAC_OVERRIDE/),
      "the recovery must name restoring the ORIGINAL top-level ceiling, not an arbitrary capability set"
    expect(script).to match(/ExecStartPre=\s*\n/),
      "the recovery must clear the inherited ExecStartPre= (an empty override), not just add capabilities back"
  end

  it "the recovery recipe actually works: sets POWERNODE_BUNDLE_FROZEN=0, discovers the real unit name, and blames /run being tmpfs (review round R4, item 7)" do
    expect(script).to match(/Environment=POWERNODE_BUNDLE_FROZEN=0/),
      "rails-start.sh exports BUNDLE_FROZEN unconditionally from POWERNODE_BUNDLE_FROZEN (default 1) -- without " \
      "this override, a capabilities-restored rails STILL refuses to rewrite a stale lock under frozen mode; " \
      "capabilities alone were never enough to make the old recipe actually work"
    expect(script).to match(/systemctl list-units 'powernode-\*-rails\.service'/),
      "CLAUDE.md: \"systemd unit names -- NEVER guess them\" -- the old recipe's literal `rails.service` target " \
      "does not exist on a module-composed node; must discover the real, agent-generated unit name first"
    expect(script).not_to match(/systemctl (?:daemon-reload && )?restart rails\.service/),
      "the literal `rails.service` target must not appear as something to restart directly"
    expect(script).to match(/\/run,? which\s*\n?#?\s*is tmpfs/),
      "the drop-in disappears on the next REBOOT because /run is tmpfs -- not on an agent reconcile, which was " \
      "the old (wrong) claim this comment made"
    expect(script).not_to match(/agent overwrites drop-ins on reconcile/),
      "the old, incorrect mechanism claim must not still be here"
  end

  it "logs the before and after PATH-gem list, not just pass/fail" do
    expect(script).to match(/PATH gems before:/)
    expect(script).to match(/PATH gems after:/)
  end

  # Genuinely EXECUTES the extracted path_gems_in_lock function against
  # real fixture lockfiles -- proving the extraction actually parses the
  # PATH block shape bundler writes, in both the multi-extension (a
  # dev/CI build, all public extensions present) and no-extension
  # (nothing composed yet) shapes. The second case is a real, previously
  # unfixed defect: a lockfile with NO PATH block makes the first grep in
  # the pipeline exit 1 with nothing for the rest of the pipe to match
  # either, and under this script's own `set -euo pipefail` that
  # propagated straight through `set -e` and aborted the WHOLE SCRIPT.
  # Fixed by `|| true` at the call site; this test pins that fix by
  # actually hitting the failure shape, not just reading the source for
  # the string `|| true`.
  it "path_gems_in_lock, actually run, extracts PATH gem remotes and tolerates a lockfile with none" do
    function_body = script[/path_gems_in_lock\(\) \{\n(.*?)\n\}/m, 1]
    expect(function_body).not_to be_nil

    Dir.mktmpdir do |dir|
      rails_dir = File.join(dir, "server")
      FileUtils.mkdir_p(rails_dir)

      run_against = lambda do |lock_contents|
        File.write(File.join(rails_dir, "Gemfile.lock"), lock_contents)
        snippet = <<~BASH
          set -euo pipefail
          RAILS_DIR=#{rails_dir}
          path_gems_in_lock() {
          #{function_body}
          }
          path_gems_in_lock || true
        BASH
        Open3.capture3("bash", "-c", snippet)
      end

      multi_extension_lock = <<~LOCK
        PATH
          remote: ../extensions/alpha/server
          specs:
            powernode_alpha (0.1.0)

        PATH
          remote: ../extensions/beta/server
          specs:
            powernode_beta (0.1.0)

        PATH
          remote: ../extensions/system/server
          specs:
            powernode_system (0.1.0)

        GEM
          remote: https://rubygems.org/
      LOCK

      out, err, status = run_against.call(multi_extension_lock)
      expect(status.success?).to be(true), "aborted on a real multi-extension lock: #{err}"
      expect(out.split("\n")).to contain_exactly(
        "../extensions/alpha/server", "../extensions/beta/server", "../extensions/system/server"
      )

      no_extension_lock = "GEM\n  remote: https://rubygems.org/\n"
      out, err, status = run_against.call(no_extension_lock)
      expect(status.success?).to be(true),
        "a lockfile with NO PATH block must not abort the script under set -e/pipefail: #{err}"
      expect(out.strip).to eq("")
    end
  end

  # Genuinely EXECUTES relock_gemfile_for_this_node (extracted verbatim
  # from the file, not retyped) against a STUB `bundle` this describe
  # block substitutes via BUNDLE_BIN -- proves the review-round fixes
  # (isolation, atomic replace, non-fatal failure) by RUNNING them, not
  # by reading the source for the right words.
  #
  # PRIVILEGE (review round, S3): the function itself now does
  # `chown -R "$RAILS_USER" ...` and `runuser -u "$RAILS_USER" -- ...`,
  # both of which require a privileged caller regardless of whether the
  # target user is the caller's own account. This suite's CI runner runs
  # rspec as root (documented invariant elsewhere in this repo); RAILS_USER
  # is set to "root" for these examples specifically so the real
  # chown/runuser calls succeed without needing a genuine, separately
  # provisioned low-privilege account on every machine these specs run on
  # -- that exercises the real code path (chown, runuser, gem spec, bundle
  # lock, in the real order, with the real arguments) even though it
  # doesn't exercise privilege dropping to a GENUINELY different uid. A
  # non-root test runner cannot exercise this at all; skip rather than
  # false-fail.
  describe "relock_gemfile_for_this_node, actually run against a stub bundle" do
    before do
      skip "requires a privileged (root) test runner -- see this describe block's header" unless Process.uid.zero?
    end

    let(:relock_function_body) do
      script[/relock_gemfile_for_this_node\(\) \{\n(.*?)\n\}\n/m, 1]
    end
    let(:path_gems_function_body) do
      script[/path_gems_in_lock\(\) \{\n(.*?)\n\}/m, 1]
    end
    # review round R4: relock_gemfile_for_this_node now re-execs into a
    # `timeout`-wrapped `bash -c` child (see that function's own
    # comment), which needs these three ALSO defined -- extracted the
    # same verbatim way, not retyped, so a regression in the real
    # function bodies fails these tests too, not just the source ones.
    let(:attempt_bundle_lock_body) do
      script[/attempt_bundle_lock\(\) \{\n(.*?)\n\}/m, 1]
    end
    let(:build_gem_stubs_body) do
      script[/build_gem_stubs\(\) \{\n(.*?)\n\}/m, 1]
    end
    let(:build_isolated_gem_home_body) do
      script[/build_isolated_gem_home\(\) \{\n(.*?)\n\}/m, 1]
    end
    let(:pin_bundled_with_body) do
      script[/pin_bundled_with\(\) \{\n(.*?)\n\}/m, 1]
    end
    # review round R5: the exact top-level block that resolves
    # BUNDLER_VERSION/BUNDLER_GEM_DIR/BUNDLER_GEMSPEC, extracted verbatim
    # (not retyped) so this suite exercises the SAME resolution logic
    # production runs, against whatever BUNDLE_BIN a given test supplies.
    let(:bundler_location_preamble) do
      script[/^BUNDLER_VERSION="\$\(timeout 15.*?^export BUNDLER_GEM_DIR BUNDLER_GEMSPEC$/m]
    end

    it "the extraction itself found the real function body (sanity-checks the extraction, not the script)" do
      expect(relock_function_body).not_to be_nil
      expect(relock_function_body).to include("trap ")
      expect(relock_function_body).to include("mv -f")
      expect(attempt_bundle_lock_body).not_to be_nil
      expect(build_gem_stubs_body).not_to be_nil
      expect(build_isolated_gem_home_body).not_to be_nil
      expect(pin_bundled_with_body).not_to be_nil
      expect(bundler_location_preamble).not_to be_nil
    end

    # Shared preamble: wires up every function relock_gemfile_for_this_node
    # depends on (directly, or via the timeout-wrapped child it re-execs
    # into) exactly the way the real script's own top level does --
    # RAILS_DIR/RAILS_USER/BUNDLE_BIN exported as real environment
    # variables (not local scope), BUNDLER_VERSION/BUNDLER_GEM_DIR/
    # BUNDLER_GEMSPEC resolved via the SAME verbatim top-level block
    # production runs (review round R5), and attempt_bundle_lock/
    # build_gem_stubs/build_isolated_gem_home exported as FUNCTIONS
    # (`export -f`) so the `bash -c` child `timeout` starts can see them
    # at all.
    def relock_preamble(rails_dir:, stub_path:)
      <<~BASH
        set -euo pipefail
        unset RUBYOPT RUBYLIB
        RAILS_DIR=#{rails_dir}
        RAILS_USER=root
        BUNDLE_BIN=#{stub_path}
        export BUNDLE_GEMFILE="$RAILS_DIR/Gemfile"
        export RAILS_DIR RAILS_USER BUNDLE_BIN
        #{bundler_location_preamble}
        path_gems_in_lock() {
        #{path_gems_function_body}
        }
        attempt_bundle_lock() {
        #{attempt_bundle_lock_body}
        }
        build_gem_stubs() {
        #{build_gem_stubs_body}
        }
        build_isolated_gem_home() {
        #{build_isolated_gem_home_body}
        }
        export -f attempt_bundle_lock build_gem_stubs build_isolated_gem_home
        pin_bundled_with() {
        #{pin_bundled_with_body}
        }
        relock_gemfile_for_this_node() {
        #{relock_function_body}
        }
      BASH
    end

    # Shared runner: invokes the extracted function via `bash -c` exactly
    # as either caller would -- same function bodies, same dependencies,
    # same BUNDLE_BIN override point.
    def run_relock(rails_dir:, stub_path:, **)
      snippet = relock_preamble(rails_dir: rails_dir, stub_path: stub_path) + <<~BASH
        relock_gemfile_for_this_node
        echo "RELOCK_EXIT=$?"
      BASH
      Open3.capture3("bash", "-c", snippet)
    end

    it "is non-fatal when bundle fails: warns, and the caller's own exit code is 0" do
      failing_stub = "#!/bin/bash\nexit 1\n"
      Dir.mktmpdir do |dir|
        rails_dir = File.join(dir, "server")
        FileUtils.mkdir_p(rails_dir)
        File.write(File.join(rails_dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n")
        stub_path = File.join(dir, "bundle")
        File.write(stub_path, failing_stub)
        FileUtils.chmod(0o755, stub_path)

        snippet = relock_preamble(rails_dir: rails_dir, stub_path: stub_path) + <<~BASH
          relock_gemfile_for_this_node || true
          echo "SCRIPT_EXIT=$?"
        BASH
        out, err, status = Open3.capture3("bash", "-c", snippet)

        expect(status.success?).to be(true), "the driving script must not abort: #{err}"
        expect(out).to include("SCRIPT_EXIT=0")
        # review round R4: the always-failing stub fails BOTH the fast
        # path and the stub fallback -- proves the fallback was actually
        # attempted, not skipped, before the overall WARNING fires.
        expect(err).to match(/fast path resolve failed/)
        expect(err).to match(/WARNING.*bundle lock --local failed/i)
      end
    end

    it "passes bundle a scratch env -- BUNDLE_APP_CONFIG/HOME/TMPDIR never under STATE_DIR or RAILS_DIR" do
      Dir.mktmpdir do |dir|
        rails_dir = File.join(dir, "server")
        state_dir = File.join(dir, "persist", "powernode-rails") # a rails-writable path this must NEVER touch
        FileUtils.mkdir_p(rails_dir)
        FileUtils.mkdir_p(state_dir)
        File.write(File.join(rails_dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n")

        env_log = File.join(dir, "env.log")
        stub = <<~STUB
          #!/bin/bash
          env | sort > "#{env_log}"
          for arg in "$@"; do
            case "$arg" in
              --lockfile=*) lockfile="${arg#--lockfile=}" ;;
            esac
          done
          cp #{File.join(rails_dir, "Gemfile.lock")} "$lockfile"
          exit 0
        STUB
        stub_path = File.join(dir, "bundle")
        File.write(stub_path, stub)
        FileUtils.chmod(0o755, stub_path)

        run_relock(rails_dir: rails_dir, stub_path: stub_path,
                   relock_function_body: relock_function_body, path_gems_function_body: path_gems_function_body)

        env_lines = File.read(env_log).lines
        %w[BUNDLE_APP_CONFIG HOME TMPDIR].each do |var|
          line = env_lines.find { |l| l.start_with?("#{var}=") }
          expect(line).not_to be_nil, "#{var} was not exported to the bundle invocation at all"
          value = line.split("=", 2).last.strip
          expect(value).not_to start_with(state_dir),
            "#{var}=#{value} points under the rails-writable STATE_DIR -- exactly the HIGH finding this fix closes"
          expect(value).not_to start_with(rails_dir),
            "#{var}=#{value} points under RAILS_DIR -- must be an isolated scratch dir instead"
        end
      end
    end

    it "cmp-equal (bundle resolves to the SAME content) makes no replacement -- inode is unchanged" do
      lock_contents = "GEM\n  remote: https://rubygems.org/\n  specs:\n    foo (1.0)\n"
      Dir.mktmpdir do |dir|
        rails_dir = File.join(dir, "server")
        FileUtils.mkdir_p(rails_dir)
        File.write(File.join(rails_dir, "Gemfile.lock"), lock_contents)
        before_inode = File.stat(File.join(rails_dir, "Gemfile.lock")).ino

        # `cp` a real fixture file, not a `cat <<HEREDOC` embedding the
        # content inline: interpolating multi-line, already-newline-
        # terminated content into a second heredoc reliably adds an
        # extra trailing blank line, which would make cmp -s see a
        # difference that was never really there.
        resolved_fixture = File.join(dir, "resolved.lock")
        File.write(resolved_fixture, lock_contents)
        # Asserts it received the CURRENT lock's content at --lockfile=
        # time, not an empty file -- this is exactly what would have
        # caught HIGH #2 (resolving from an empty temp lockfile).
        stub = <<~STUB
          #!/bin/bash
          for arg in "$@"; do
            case "$arg" in
              --lockfile=*) lockfile="${arg#--lockfile=}" ;;
            esac
          done
          if [ ! -s "$lockfile" ]; then
            echo "STUB: --lockfile was EMPTY at invocation time -- not seeded from the current lock" >&2
            exit 1
          fi
          if ! cmp -s "$lockfile" #{File.join(rails_dir, "Gemfile.lock")}; then
            echo "STUB: --lockfile did not contain the CURRENT lock's content at invocation time" >&2
            exit 1
          fi
          cp #{resolved_fixture} "$lockfile"
          exit 0
        STUB
        stub_path = File.join(dir, "bundle")
        File.write(stub_path, stub)
        FileUtils.chmod(0o755, stub_path)

        out, err, status = run_relock(rails_dir: rails_dir, stub_path: stub_path,
                                       relock_function_body: relock_function_body,
                                       path_gems_function_body: path_gems_function_body)

        expect(status.success?).to be(true), "aborted: #{err}"
        expect(out).to include("RELOCK_EXIT=0")
        expect(out).to include("already matches")
        after_inode = File.stat(File.join(rails_dir, "Gemfile.lock")).ino
        expect(after_inode).to eq(before_inode), "the file was replaced even though bundler resolved to identical content"

        leftover = Dir.glob(File.join(rails_dir, "Gemfile.lock.relock*"))
        expect(leftover).to be_empty, "a temp lockfile was left behind: #{leftover.inspect}"

        # review round R4, item 1: the matching-lock (fast) path must
        # NEVER build vendor/cache stubs at all -- this stub bundle
        # succeeds unconditionally on its very first call, so if the fast
        # path were skipped (or if it failed and the fallback masked
        # that), stderr would show the "resolve failed"/"building
        # vendor/cache gemspec stubs" log line instead of this one.
        expect(err).to match(/fast path \(bundler-isolated, no vendor\/cache stubs\) resolved successfully/),
          "the matching-lock path must take the fast, no-stub branch -- this is the marker this test asserts on"
        expect(err).not_to match(/building vendor\/cache gemspec stubs/),
          "stubs must never be built when the fast path already succeeded"
      end
    end

    it "a DIFFERENT resolve replaces the lockfile atomically (mv), and leaves no temp file behind" do
      old_contents = "GEM\n  remote: https://rubygems.org/\n  specs:\n    foo (1.0)\n"
      new_contents = <<~LOCK
        PATH
          remote: ../extensions/system/server
          specs:
            powernode_system (0.1.0)

        GEM
          remote: https://rubygems.org/
          specs:
            foo (1.0)
      LOCK

      Dir.mktmpdir do |dir|
        rails_dir = File.join(dir, "server")
        FileUtils.mkdir_p(rails_dir)
        gemfile_lock_path = File.join(rails_dir, "Gemfile.lock")
        File.write(gemfile_lock_path, old_contents)
        # The ORIGINAL's mode -- deliberately NOT 0600 (what mktemp
        # would leave the temp file at), so a regression of HIGH #1
        # would be visible: 0644, matching what root's own umask
        # normally leaves a plain `File.open(..., "w")`-created file
        # at, and what rails actually needs to be able to read it via.
        FileUtils.chmod(0o644, gemfile_lock_path)
        original_uid = File.stat(gemfile_lock_path).uid
        original_gid = File.stat(gemfile_lock_path).gid

        # `cp` a real fixture file -- see the cmp-equal test above for why
        # not a nested heredoc. Also asserts it received the CURRENT
        # lock's content at --lockfile= time (would have caught HIGH #2).
        resolved_fixture = File.join(dir, "resolved.lock")
        File.write(resolved_fixture, new_contents)
        stub = <<~STUB
          #!/bin/bash
          for arg in "$@"; do
            case "$arg" in
              --lockfile=*) lockfile="${arg#--lockfile=}" ;;
            esac
          done
          if [ ! -s "$lockfile" ]; then
            echo "STUB: --lockfile was EMPTY at invocation time -- not seeded from the current lock" >&2
            exit 1
          fi
          if ! cmp -s "$lockfile" #{gemfile_lock_path}; then
            echo "STUB: --lockfile did not contain the CURRENT lock's content at invocation time" >&2
            exit 1
          fi
          cp #{resolved_fixture} "$lockfile"
          exit 0
        STUB
        stub_path = File.join(dir, "bundle")
        File.write(stub_path, stub)
        FileUtils.chmod(0o755, stub_path)

        out, err, status = run_relock(rails_dir: rails_dir, stub_path: stub_path,
                                       relock_function_body: relock_function_body,
                                       path_gems_function_body: path_gems_function_body)

        expect(status.success?).to be(true), "aborted: #{err}"
        expect(out).to include("RELOCK_EXIT=0")
        expect(out).to include("re-locked Gemfile.lock")
        expect(out).to include("../extensions/system/server")
        expect(File.read(gemfile_lock_path)).to eq(new_contents)

        final_stat = File.stat(gemfile_lock_path)
        expect(final_stat.mode & 0o777).to eq(0o644),
          "expected the swapped-in lockfile to keep the ORIGINAL's 0644 mode, got #{(final_stat.mode & 0o777).to_s(8)} " \
          "-- mktemp creates the temp file 0600, and mv installs it with whatever mode it already had (HIGH #1)"
        expect(final_stat.uid).to eq(original_uid), "owner changed across the swap"
        expect(final_stat.gid).to eq(original_gid), "group changed across the swap"

        leftover = Dir.glob(File.join(rails_dir, "Gemfile.lock.relock*"))
        expect(leftover).to be_empty,
          "a temp lockfile was left behind: #{leftover.inspect} -- review round R4 added a SECOND temp-file " \
          "shape (Gemfile.lock.relock-final.XXXXXX, the fresh root-owned file the final swap goes through) " \
          "that must be cleaned up too, not just the original Gemfile.lock.relock.XXXXXX"
      end
    end

    # S4's own repro, against the REAL bundle/gem toolchain (no stub) --
    # a PATH-gem-shaped drift is unnecessary to reproduce this: any
    # dependency present in vendor/cache but absent from the current lock
    # hits the identical `with_cache!`-less code path in bundler's
    # cli/lock.rb. Uses two small, pure-Ruby, no-native-extension gems
    # (rake, matrix) so this stays fast and needs no network (matches
    # this suite's `--local` invariant once vendor/cache is pre-seeded
    # from the real, already-resolved gems below).
    #
    # review round R4 note: this is an END-TO-END proof (the real
    # relock_gemfile_for_this_node, real bundler, real gem toolchain) that
    # the overall feature still works -- it does NOT pin down WHICH of the
    # fast path or the stub fallback actually resolved matrix, because
    # matrix happens to be genuinely, ambiently gem-installed on many
    # machines (this one included) regardless of GEM_PATH, so the fast
    # path can legitimately succeed here without ever reaching the
    # fallback. The fallback mechanism ITSELF, and the GEM_PATH-narrowing
    # correctness fix specifically, are pinned down deterministically
    # (independent of what happens to be installed on the machine running
    # this suite) by the two tests immediately below instead.
    it "S4: a dependency present ONLY in vendor/cache (absent from the current lock) resolves correctly, and frozen rails then boots against the result" do
      Dir.mktmpdir do |dir|
        rails_dir = File.join(dir, "server")
        FileUtils.mkdir_p(File.join(rails_dir, "vendor/cache"))

        gemfile_path = File.join(rails_dir, "Gemfile")
        gemfile_lock_path = File.join(rails_dir, "Gemfile.lock")

        # -u GEM_HOME/-u GEM_PATH: `bundle exec` (this suite's own runner)
        # sets GEM_HOME to the CURRENT worktree's own vendor/bundle for its
        # own child processes -- stripped here (unsetenv_others: true, see
        # the main relock invocation below for the full reasoning) so this
        # reflects the real, system-wide Gem.path a genuinely standalone
        # process would see, not this test run's own bundled environment.
        clean_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        real_gem_path = `env -i PATH=#{clean_path} ruby -e 'puts Gem.path.join(":")'`.strip

        # Resolve rake/matrix's version AND cached .gem path from the SAME
        # clean, system-only Gem.path the baseline lock below uses -- not
        # this process's own (via `bundle exec rspec`, worktree-specific)
        # Gem::Specification.find_by_name. Verified live these can
        # genuinely disagree (this process's own worktree had rake 13.4.2
        # bundled; the clean system path only had 13.0.6), and pinning the
        # WRONG version into both the Gemfile and vendor/cache would fail
        # the final boot step for a reason unrelated to what this test
        # actually proves.
        probe = <<~RUBY
          %w[rake matrix].each do |name|
            spec = Gem::Specification.find_by_name(name)
            puts [name, spec.version, File.join(Gem.dir, "cache", "\#{spec.full_name}.gem")].join(" ")
          end
        RUBY
        probe_out, probe_err, probe_status = Open3.capture3(
          { "PATH" => clean_path }, "ruby", "-e", probe, unsetenv_others: true
        )
        skip "could not resolve rake/matrix from the clean system gem path: #{probe_err}" unless probe_status.success?
        gems = probe_out.lines.map { |l| l.split(" ") }.to_h { |name, version, path| [ name, { version: version, path: path } ] }

        # The drifted lock: a REAL lock, generated by the real toolchain,
        # for the Gemfile as it stood BEFORE "matrix" was added -- not
        # hand-written YAML-shaped text, which risks silently not matching
        # what this machine's actual bundler would ever produce (platform
        # list, BUNDLED WITH, etc) and masking the very bug this proves.
        File.write(gemfile_path, "source \"https://rubygems.org\"\ngem \"rake\", \"#{gems['rake'][:version]}\"\n")
        lock_out, lock_err, lock_status = Open3.capture3(
          { "PATH" => clean_path, "BUNDLE_GEMFILE" => gemfile_path, "GEM_PATH" => real_gem_path },
          "bundle", "lock", "--local",
          unsetenv_others: true
        )
        skip "could not generate the baseline (pre-drift) lock on this machine: #{lock_out}\n#{lock_err}" unless lock_status.success?

        # Populate vendor/cache from THIS machine's real, already-resolved
        # gems -- the exact same specs pinned into the Gemfile above.
        gems.each_value do |g|
          skip "#{g[:path]} is not available as a cached .gem on this machine -- cannot run this repro" unless File.exist?(g[:path])
          FileUtils.cp(g[:path], File.join(rails_dir, "vendor/cache", File.basename(g[:path])))
        end

        # NOW add matrix to the Gemfile -- the lock on disk still reflects
        # the OLD (rake-only) Gemfile, exactly the drift this fix repairs.
        File.write(gemfile_path,
                   "source \"https://rubygems.org\"\n" \
                   "gem \"rake\", \"#{gems['rake'][:version]}\"\n" \
                   "gem \"matrix\", \"#{gems['matrix'][:version]}\"\n")
        FileUtils.chmod(0o644, gemfile_lock_path)

        # unsetenv_others: true -- this suite itself runs under `bundle
        # exec rspec`, which pollutes the environment for EVERY child
        # process (RUBYOPT auto-requiring bundler/setup, GEM_HOME/GEM_PATH
        # pinned to THIS worktree's own vendor/bundle, BUNDLE_GEMFILE set
        # to this worktree's real Gemfile). `unset`-ing individual vars
        # inside the snippet chased several of these one at a time and
        # still missed enough to make the real bundle process silently
        # resolve against the WRONG environment (verified live: RUBYOPT/
        # RUBYLIB alone were not sufficient). Clearing everything except
        # what's explicitly listed below is the only reliable way to
        # prove this against a clean environment -- which also happens to
        # be the environment this script ACTUALLY runs in in production
        # (a bare systemd ExecStartPre/rails-setup.sh subprocess call,
        # never itself launched via `bundle exec`).
        out, err, status = Open3.capture3(
          { "PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" },
          "bash", "-c",
          relock_preamble(rails_dir: rails_dir, stub_path: "/usr/local/bin/bundle") + <<~BASH,
            relock_gemfile_for_this_node
            echo "RELOCK_EXIT=$?"
          BASH
          unsetenv_others: true
        )

        expect(status.success?).to be(true), "aborted: #{err}"
        expect(out).to include("RELOCK_EXIT=0")
        expect(out).to include("re-locked Gemfile.lock")

        resolved = File.read(gemfile_lock_path)
        expect(resolved).to match(/^\s*matrix \(/), "matrix was not resolved into the lock: #{resolved}"
        expect(resolved).to match(/^\s*rake \(/)

        # vendor/cache itself must be untouched -- the resolve reads it,
        # never writes to it (no `gem install`, no cache prune).
        cache_files = Dir.glob(File.join(rails_dir, "vendor/cache/*.gem")).map { |f| File.basename(f) }
        expect(cache_files.size).to eq(2)

        # Frozen rails (rails-start.sh, IMP-094d900f9093 part 2) must now
        # boot successfully against the repaired lock -- the actual point
        # of fixing this.
        boot_bundle_path = File.join(dir, "boot-bundle-path")
        FileUtils.mkdir_p(boot_bundle_path)
        boot_out, boot_err, boot_status = Open3.capture3(
          { "PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "BUNDLE_GEMFILE" => File.join(rails_dir, "Gemfile"),
            "BUNDLE_PATH" => boot_bundle_path,
            "BUNDLE_FROZEN" => "1" },
          "bundle", "install", "--local", "--jobs", "4",
          chdir: rails_dir,
          unsetenv_others: true
        )
        expect(boot_status.success?).to be(true),
          "frozen rails failed to boot against the repaired lock: #{boot_out}\n#{boot_err}"
      end
    end

    # review round R4, item 1/2/5: deterministic proof that the FALLBACK
    # mechanism itself (build_gem_stubs + attempt_bundle_lock called
    # directly with a real gem_home) resolves a dependency that exists
    # ONLY as a stub-registered vendor/cache gem -- independent of
    # whatever the fast path can or can't already see ambiently on the
    # machine running this suite (see the note above the S4 test).
    it "the stub fallback (build_gem_stubs + attempt_bundle_lock with a real gem_home) resolves a dependency registered ONLY via the stub, deterministically" do
      Dir.mktmpdir do |dir|
        rails_dir = File.join(dir, "server")
        FileUtils.mkdir_p(File.join(rails_dir, "vendor/cache"))
        gemfile_path = File.join(rails_dir, "Gemfile")
        gemfile_lock_path = File.join(rails_dir, "Gemfile.lock")

        clean_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        probe = <<~RUBY
          spec = Gem::Specification.find_by_name("rake")
          puts [spec.version, File.join(Gem.dir, "cache", "\#{spec.full_name}.gem")].join(" ")
        RUBY
        probe_out, probe_err, probe_status = Open3.capture3({ "PATH" => clean_path }, "ruby", "-e", probe, unsetenv_others: true)
        skip "could not resolve rake from the clean system gem path: #{probe_err}" unless probe_status.success?
        version, cached_path = probe_out.strip.split(" ")
        skip "#{cached_path} is not available as a cached .gem on this machine" unless File.exist?(cached_path)
        FileUtils.cp(cached_path, File.join(rails_dir, "vendor/cache", File.basename(cached_path)))

        File.write(gemfile_path, "source \"https://rubygems.org\"\ngem \"rake\", \"#{version}\"\n")
        File.write(gemfile_lock_path, "GEM\n  remote: https://rubygems.org/\n")

        out, err, status = Open3.capture3(
          { "PATH" => clean_path },
          "bash", "-c",
          relock_preamble(rails_dir: rails_dir, stub_path: "/usr/local/bin/bundle") + <<~BASH,
            gem_stub_dir="$(mktemp -d)"
            chmod 0755 "$gem_stub_dir"
            mkdir -p "$gem_stub_dir/specifications"
            build_gem_stubs "$gem_stub_dir"
            BUNDLE_APP_CONFIG="$(mktemp -d)"
            HOME="$(mktemp -d)"
            TMPDIR="$(mktemp -d)"
            export BUNDLE_APP_CONFIG HOME TMPDIR POWERNODE_DEPLOYED=1
            attempt_bundle_lock #{gemfile_lock_path} "$gem_stub_dir" && echo "ATTEMPT_EXIT=0" || echo "ATTEMPT_EXIT=$?"
          BASH
          unsetenv_others: true
        )

        expect(status.success?).to be(true), "aborted: #{err}"
        expect(out).to include("ATTEMPT_EXIT=0"), "stub-only resolve failed: #{err}"
        resolved = File.read(gemfile_lock_path)
        expect(resolved).to match(/^\s*rake \(/), "rake was not resolved via the stub: #{resolved}"
      end
    end

    # review round R4, item 3: deterministic proof that the fallback's
    # GEM_PATH does NOT fall through to whatever this process's own
    # AMBIENT Gem.path already contains -- the critic's exact regression
    # (a dependency resolvable from real, ambiently-installed gems but
    # genuinely ABSENT from vendor/cache got silently pinned into the
    # lock under the OLD `GEM_PATH="$gem_stub_dir:$real_gem_path"` shape,
    # and a REAL frozen `bundle install --local` -- exactly what rails
    # does at boot, vendor/cache only -- then failed). Deterministic and
    # independent of what happens to be installed on the machine running
    # this suite: supplies its OWN fake "ambient" Gem.path (a gem name
    # that will never collide with a real published one) via the
    # CALLING process's own GEM_PATH/GEM_HOME, and asserts the resolve
    # fails when attempt_bundle_lock is given a DIFFERENT, empty
    # gem_home -- proving GEM_PATH="$gem_home" replaces, rather than
    # merges with, whatever was ambiently set.
    it "the fallback's GEM_PATH does not fall through to this process's ambient Gem.path (review round R4, item 3 -- the critic's regression)" do
      Dir.mktmpdir do |dir|
        rails_dir = File.join(dir, "server")
        FileUtils.mkdir_p(File.join(rails_dir, "vendor/cache")) # deliberately left EMPTY
        gemfile_path = File.join(rails_dir, "Gemfile")
        gemfile_lock_path = File.join(rails_dir, "Gemfile.lock")

        fake_ambient_gem_path = Dir.mktmpdir
        FileUtils.mkdir_p(File.join(fake_ambient_gem_path, "specifications"))
        File.write(
          File.join(fake_ambient_gem_path, "specifications", "widget-1.0.0.gemspec"),
          Gem::Specification.new("widget", "1.0.0").to_ruby
        )

        File.write(gemfile_path, "source \"https://rubygems.org\"\ngem \"widget\", \"1.0.0\"\n")
        File.write(gemfile_lock_path, "GEM\n  remote: https://rubygems.org/\n")

        clean_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        empty_stub_dir = Dir.mktmpdir
        FileUtils.mkdir_p(File.join(empty_stub_dir, "specifications")) # "widget" NOT registered here

        out, err, status = Open3.capture3(
          # Simulates "widget happens to be ambiently installed on this
          # machine" -- GEM_PATH/GEM_HOME set in the CALLING process's
          # own environment, exactly the shape a real, differently-
          # populated system Gem.path would take.
          { "PATH" => clean_path, "GEM_PATH" => fake_ambient_gem_path, "GEM_HOME" => fake_ambient_gem_path },
          "bash", "-c",
          relock_preamble(rails_dir: rails_dir, stub_path: "/usr/local/bin/bundle") + <<~BASH,
            BUNDLE_APP_CONFIG="$(mktemp -d)"
            HOME="$(mktemp -d)"
            TMPDIR="$(mktemp -d)"
            export BUNDLE_APP_CONFIG HOME TMPDIR POWERNODE_DEPLOYED=1
            attempt_bundle_lock #{gemfile_lock_path} #{empty_stub_dir} && echo "ATTEMPT_EXIT=0" || echo "ATTEMPT_EXIT=$?"
          BASH
          unsetenv_others: true
        )

        expect(status.success?).to be(true), "the driving script must not abort: #{err}"
        expect(out).not_to include("ATTEMPT_EXIT=0"),
          "widget resolved even though it is registered ONLY in the fake ambient Gem.path, not in the gem_home " \
          "attempt_bundle_lock was actually given -- GEM_PATH=\"$gem_home\" must REPLACE, not merge with, " \
          "whatever was ambiently set (this is exactly the critic's regression: a system-only gem silently " \
          "pinned into the lock, then unavailable at a REAL frozen boot, which only ever sees vendor/cache)"
        expect(err).to match(/could not find gem 'widget/i)
      end
    end
  end
end
