#!/bin/bash
# rails-relock-gemfile.sh — root-only re-lock of Gemfile.lock for THIS
# NODE's actual extension composition (IMP-01a0e40a-c0ef, follow-up to
# IMP-caef5c00d63f's zero-cap rails goal; extracted from rails-setup.sh
# into a standalone script by IMP-094d900f9093 part 2 — see below for why).
#
# TWO CALLERS, same logic, one script:
#   1. rails-setup.sh calls this once per boot, as part of its root-only
#      prep sweep, before rails ever starts (RemainAfterExit=yes — see
#      that script's own header for why the whole unit exists).
#   2. rails.service's own `ExecStartPre=-+/usr/local/bin/
#      rails-relock-gemfile.sh` calls this on EVERY rails start, not just
#      once per boot. The `+` prefix runs this ONE command with full
#      privileges, exempt from rails.service's own User=/
#      CapabilityBoundingSet=[] (systemd.service(5): "If the executable
#      path is prefixed with '+' ... executed with full privileges") — so
#      this still works after rails itself has zero capabilities. The
#      leading `-` (review round) makes a FAILURE of this one line —
#      including 203/EXEC if this file is ever missing or not
#      executable — non-fatal to the unit; without it, a broken helper
#      here would cancel rails' own start job the same way rails-setup's
#      lost executable bit once did (see this task's own B1 finding).
#
# WHY CALLER 2 EXISTS (IMP-094d900f9093 part 2, blocker (b) from part 1's
# review): rails-setup.sh runs once per BOOT, ordered `start_before` rails
# via the manifest's `dependencies:`. A LIVE module refresh that restarts
# ONLY the `rails` unit does NOT re-run rails-setup.sh — checked directly
# against the agent, not assumed: rails' `start_before` edge on rails-setup
# renders as Requires=+After= on rails.service
# (agent/internal/lifecycle/service.go, writeDependencyDirectives), and the
# agent's restart task issues a single-unit `systemctl restart <unit>`
# (agent/internal/systemd/units.go, Action) — restart does not cascade to
# units named in another unit's Requires=, and rails-setup.service stays
# "active (exited)" (RemainAfterExit=yes) from the boot that ran it, so no
# new start job for it is ever queued by restarting rails alone. If the
# node's extension composition ever changed via such a refresh (without a
# matching hub-backend rebuild+redeploy), nothing would repair a stale
# lock, and rails at capabilities:[] has no capability left to repair it
# itself either. Caller 2 closes this: every rails start (not just every
# boot) gets a root-privileged re-lock attempt first, regardless of what
# restarted it or when.
#
# ROOT CAUSE (the resolution mismatch this repairs): extensions_loader_
# helper.rb's discover_extension_gems_by_visibility only includes an
# extension as a Gemfile PATH gem when POWERNODE_DEPLOYED=1 is set AND the
# extension is actually present on disk under extensions/. The COMMITTED
# Gemfile.lock is built once, in dev/CI, with every PUBLIC extension
# present as a git submodule — it does not necessarily match what any ONE
# node composes (ops-hub composes only extensions/system, confirmed live).
# Bundler.setup then finds the Gemfile and Gemfile.lock disagree and
# rewrites the lock itself the moment ANYTHING calls it — which used to be
# the non-root `rails` process's own first `bundle exec`, needing
# CAP_DAC_OVERRIDE on the root-owned lockfile to succeed. Confirmed
# directly (2026-09-27): a `bundle lock --local` run reproduces the live
# lockfile byte-for-byte when POWERNODE_DEPLOYED=1 is set; the same
# command without it drops the extension entirely.
#
# IMP-094d900f9093 part 1 ships a build-time assertion that the shipped
# Gemfile.lock already matches the deployed composition, closing the
# common case before this script ever needs to act. This script remains
# the backstop for the two cases that assertion cannot reach: caller 1's
# original case (a build/composition mismatch the assertion missed or an
# older image), and caller 2's case above (composition changes after the
# module was built).
#
# SECURITY (review round, HIGH — this undid IMP-3731023204f2): the first
# draft of this section pointed Bundler at THIS NODE's REAL BUNDLE_APP_
# CONFIG/BUNDLE_PATH ($BUNDLE_CONFIG_DIR / $BUNDLE_STATE_DIR, both under
# STATE_DIR, which is rails-owned 0700). Bundler evaluates every installed
# gem's *.gemspec as ordinary Ruby whenever that gem's fast-path stub
# header is missing — reproduced live, against bundler 2.7.1, for BOTH
# `bundle check` and `bundle lock --local`. A compromised/buggy rails
# process can therefore plant or edit a gemspec under $BUNDLE_STATE_DIR,
# and root would execute it AS ROOT at the very next boot — exactly the
# escalation shape IMP-3731023204f2 closed everywhere else in rails-
# setup.sh, reopened here by handing root's own Bundler config to
# rails-writable state. rails-setup.sh's symlink guard on
# $BUNDLE_CONFIG_DIR does not help: it protects the WRITE of that config
# file, not a later READ of it (or of anything under the BUNDLE_PATH it
# names) by an unrelated root command.
#
# FIX: resolve entirely inside an ISOLATED, root-owned scratch directory
# instead of any rails-writable path. BUNDLE_APP_CONFIG, BUNDLE_PATH, HOME
# and TMPDIR all point under a fresh `mktemp -d` this function owns
# exclusively and deletes before it returns (see
# relock_gemfile_for_this_node's own trap, below) — nothing rails has ever
# touched is reachable from there, so nothing rails plants can be
# evaluated as root. Verified this still resolves correctly: reproduced
# live (2026-09-27) with this exact isolation, byte-for-byte identical to
# the real lockfile.
#
# SECOND REVIEW ROUND — two more HIGH findings in the isolation fix
# itself, both against the corrected version below:
#
# HIGH #1 (mode): `mktemp` creates the temp lockfile 0600. `mv -f` installs
# it with whatever mode it already had — a 0600 result, every boot, since
# the overlay this lockfile lives on resets. rails no longer reads the
# real Gemfile.lock via any inherited capability (IMP-094d900f9093 part
# 2 — rails runs at capabilities:[]), and powernode-rails-exec (runuser,
# no elevated capabilities at all) already cannot read a 0600 root-owned
# file — a 0600 result here would break both. Fixed by
# `chmod --reference=`/`chown --reference=` against the CURRENT
# Gemfile.lock right before the swap, with a literal `chmod 0644` fallback
# if the reference form can't read the original for some reason.
#
# HIGH #2 (resolves from an EMPTY lock): `--lockfile=$tmp_lockfile` told
# Bundler to read the LOCKED STATE from that path — and `mktemp` leaves it
# EMPTY. Reproduced live: against the isolated, empty BUNDLE_PATH above,
# bundler 2.7 either fails outright ("Could not find gem 'rails (~>
# 8.1.2)' in locally installed gems") or, depending on what's in the
# vendored gem cache, silently RE-RESOLVES FROM SCRATCH — different gem
# versions than the real app is running, CHECKSUMS dropped. Fixed by
# seeding the temp file with the CURRENT Gemfile.lock's content (`cp -p`,
# which also mostly closes HIGH #1 as a side effect — kept as an explicit
# step anyway, see above) BEFORE calling `bundle lock --local`, so Bundler
# resolves from the real locked state, offline, exactly as intended.
# Verified live: with this seed, an empty BUNDLE_PATH produces the
# expected result, and a second run reports "already matches" with no temp
# file left behind either time.
#
# `bundle check` is DROPPED (review round). It hit the identical
# gemspec-eval path against the SAME rails-owned BUNDLE_PATH the lock step
# used to — the same escalation — and once that path moved to the
# isolated scratch dir above, `check` and `lock` would be reading
# DIFFERENT installed-gem state and could disagree, making a passing
# check's "already matches" message actively misleading. `bundle lock
# --local` now runs every time this script is invoked unconditionally; it
# is still cheap (see the `--local` paragraph below) and the cmp-based
# skip a few lines down gives back the "nothing to do" fast path a
# different way — by comparing RESULTS, not by trusting a check against
# untrusted installed state.
#
# ATOMIC replace, never a write in place (review round — this also closes
# an ENOSPC-truncation risk): resolve into a TEMP lockfile living in
# $RAILS_DIR itself (`--lockfile=`, same filesystem as the real one, so
# the final `mv -f` is a same-fs rename, not a cross-filesystem copy),
# `cmp -s` it against the real Gemfile.lock, and only replace when they
# differ. A resolve that exhausts the overlay mid-write now leaves the
# ORIGINAL lockfile untouched — writing straight to Gemfile.lock, by
# contrast, could hit ENOSPC partway through and leave a truncated,
# unparseable lock in its place.
#
# `timeout 120` (review round; review round R4 moved it to wrap the
# WHOLE resolve, not just the final `bundle lock` call — see that
# function's own comment): caller 2 runs this on every rails start, so
# an offline resolve that wedges (a corrupt local gem-cache entry, a
# stuck lock, or — after R4 — a stub-generation pass over a huge
# vendor/cache) must degrade loudly on a bounded timer rather than hang
# rails' own start job indefinitely. This bound is only real if rails'
# OWN unit gives it room: `ExecStartPre=` counts against the unit's
# TimeoutStartSec (default 90s for Type=simple), which is SHORTER than
# this 120s+10s-kill bound — without raising it, systemd kills the whole
# start job at 90s, before this timeout ever gets to fire and log
# anything. rails' unit_body sets `TimeoutStartSec=180` for exactly this
# reason (IMP-094d900f9093 part 2, review round) — do not lower it below
# this script's own bound (120+10) without lowering both together.
#
# `--local` still means no network and no compilation — purely
# re-resolving the dependency graph from gemspecs and the vendored gem
# cache. Measured directly: `bundle lock --local` alone does not grow the
# root overlay's disk usage; `bundle install` (which compiles native
# extensions) does. Never call `bundle install` here.
#
# NON-FATAL, LOUDLY, ON PURPOSE — read this before changing it: a failure
# IN THIS SCRIPT must not stop rails-setup.sh's other prep (caller 1) or
# cancel rails' own start job (caller 2, via ExecStartPre=-+ — a nonzero
# ExecStartPre DOES cancel the unit's start unless leading-`-`'d, which is
# why this script always exits 0 itself; see the bottom of this file).
#
# THIS IS NOT THE SAME CLAIM AS "an un-re-locked Gemfile.lock can never
# crash-loop rails" — that used to be true here and is NOT true anymore
# (review round, corrected): with rails at capabilities:[] and
# BUNDLE_FROZEN=1 (IMP-094d900f9093 part 2), if THIS script's own resolve
# fails (corrupt vendor/cache, a gemspec it can't parse, timeout) AND the
# on-disk lock is GENUINELY stale (the Gemfile and lock truly disagree,
# not just "this script couldn't confirm they agree"), rails' own boot
# (`bundle install --local` under BUNDLE_FROZEN=1) fails loud (exit 16)
# and Restart=always retries forever — a real crash loop, not a
# hypothetical one, and this script cannot fix itself out of it because
# caller 2 runs the SAME failing resolve on every single restart.
#
# RECOVERY, when that happens: rails needs its capabilities back, one
# time, so its OWN Bundler.setup can self-heal the lock the way it did
# before this task. Drop an override at
# /run/systemd/system/powernode-<module-id>-rails.service.d/zz-emergency.conf:
#   [Service]
#   CapabilityBoundingSet=CAP_CHOWN CAP_FOWNER CAP_DAC_OVERRIDE
#   AmbientCapabilities=CAP_CHOWN CAP_FOWNER CAP_DAC_OVERRIDE
#   ExecStartPre=
#   Environment=POWERNODE_BUNDLE_FROZEN=0
# (the empty `ExecStartPre=` line clears the inherited ExecStartPre=,
# not just this drop-in's own — see systemd.service(5) on repeated-vs-
# reset directives). The POWERNODE_BUNDLE_FROZEN=0 line (review round R4,
# comment fix) is NOT optional: rails-start.sh exports
# `BUNDLE_FROZEN="${POWERNODE_BUNDLE_FROZEN:-1}"`, so without this
# override a capabilities-restored rails STILL refuses to rewrite a
# stale lock under frozen mode — capabilities alone do not undo that.
# Discover the actual unit name first (CLAUDE.md: "systemd unit names —
# NEVER guess them" — it is agent-generated per module/service, e.g.
# `powernode-<module-id>-rails.service`, never the literal `rails.service`):
#   systemctl list-units 'powernode-*-rails.service' --no-pager --no-legend
# then `systemctl daemon-reload && systemctl restart <that unit>`. This is
# a manual, root, on-host operation — the drop-in lives under /run, which
# is tmpfs, so it disappears on the next REBOOT (not on an agent
# reconcile) — treat it as temporary and fix the actual drift
# (composition, vendor/cache, or a bad build) before that reboot removes it.
#
# REVERSED, IMP-094d900f9093 part 2: this used to read "rails currently
# still holds the module's capability ceiling and can repair this itself
# on its own Bundler.setup -- but that stops being a safety net once
# rails' capabilities are narrowed to []", with two blockers for rails=[]
# listed as unresolved:
#   (a) rails-start.sh's own first-boot `bundle install --local` (taken
#       whenever $BUNDLE_PATH is empty — first boot, or any boot after a
#       wiped /persist) touching Gemfile.lock's mtime. CLOSED: rails-
#       start.sh's install now runs with BUNDLE_FROZEN=1. Verified live
#       with real Ruby 3.2.8 + Bundler 2.7.1: with BUNDLE_FROZEN unset, a
#       non-owning, zero-capability process running `bundle install
#       --local` against a root-owned, byte-identical-to-Gemfile lock
#       fails outright (Bundler::PermissionError, exit 23) the moment
#       bundler's own write_lock tries `FileUtils.touch` on the lockfile
#       to refresh its mtime, even though it never changes the CONTENT
#       (bundler/lib/bundler/definition.rb's write_lock: `if
#       lockfiles_equal?(...); return if Bundler.frozen_bundle?; ...
#       FileUtils.touch(file); return; end`) — FileUtils.touch succeeds
#       for an OWNING user regardless of the file's write bit (utime() is
#       an ownership-gated syscall, not a write-permission-gated one),
#       which is exactly why it silently worked whenever rails still held
#       CAP_DAC_OVERRIDE/ownership-equivalent access, and exactly why it
#       stopped working the moment rails did not. With BUNDLE_FROZEN=1,
#       the SAME `return if Bundler.frozen_bundle?` line returns BEFORE
#       the touch — confirmed live: install succeeds (gems land in the
#       empty BUNDLE_PATH, exit 0), and the lock's sha AND mtime are both
#       byte-for-byte unchanged. A genuine Gemfile/lock mismatch under
#       BUNDLE_FROZEN=1 fails loud (exit 16, "frozen mode is set") without
#       touching the lock at all — strictly safer than the old backstop
#       for a process that cannot repair the lock either way now.
#   (b) a live module refresh that restarts ONLY the `rails` unit not
#       re-running rails-setup.sh. CLOSED by this script's caller 2 above
#       (rails.service's own ExecStartPre=-+): every rails start now gets a
#       root-privileged re-lock attempt, not just every boot.
# Both closed, this script no longer needs anything more than the module's
# top-level security ceiling grants rails-setup — nothing here runs as
# rails itself, and nothing here changed rails-setup's own capabilities.
#
# OWNERSHIP: nothing to sweep here — the isolation fix above means this
# script never writes anything under STATE_DIR at all; everything it
# touches lives in a scratch dir it creates and destroys itself, and the
# real Gemfile.lock replacement is a single atomic rename within
# $RAILS_DIR, not a directory bundler was ever given write access to.
set -euo pipefail

RAILS_DIR=/opt/powernode/server
RAILS_USER=powernode-rails
export BUNDLE_GEMFILE="$RAILS_DIR/Gemfile"
# RAILS_DIR/RAILS_USER also exported (review round R4): the fast-path/
# stub-fallback helpers below run inside a `timeout`-wrapped child
# process (see relock_gemfile_for_this_node's own comment for why), so
# they see these only via the environment, not this script's own local
# scope.
export RAILS_DIR RAILS_USER

# The PATH-gem `remote:` lines from every PATH block in the current lock —
# the before/after signal this script logs, not a full lockfile diff.
# `|| true` at every CALL site (not baked into the function itself, so a
# genuine failure elsewhere in the pipeline isn't masked by accident): a
# lockfile with NO PATH block at all makes the first grep exit 1 with
# nothing for the rest of the pipe to match either, and under this
# script's `set -o pipefail` that failure would otherwise propagate
# through `set -e` and abort this script over a LOGGING helper — a
# self-inflicted failure, not a real error. An empty result here is a
# legitimate, expected reading (a lockfile with no extension composed
# yet), not a failure.
path_gems_in_lock() {
  grep -A1 '^PATH$' "$RAILS_DIR/Gemfile.lock" 2>/dev/null | grep 'remote:' | sed 's/^ *remote: *//' | sort
}

# BUNDLE_BIN, not a hardcoded literal: lets a spec point this at a stub
# executable instead of the real bundler, so the behavioral properties
# below (isolation, atomic replace, non-fatal failure) can be exercised
# without needing a real gem environment. Unset/default in production —
# every invocation resolves to the same /usr/local/bin/bundle it always did.
BUNDLE_BIN="${BUNDLE_BIN:-/usr/local/bin/bundle}"
export BUNDLE_BIN

# The actually-running bundler's own version, computed once -- see
# `pin_bundled_with` below for why this is needed at all (an isolated
# resolve's narrowed GEM_PATH can make bundler fall back to a DIFFERENT,
# wrong version for the lock's own "BUNDLED WITH" line). `|| true`: a
# BUNDLE_BIN that fails `--version` (a broken test stub, say) must not
# abort this whole script under `set -e` before the real work below even
# gets a chance to run non-fatally. `timeout 15` (review round R5,
# Critic-1 nit): caller 1 is rails-setup.sh, a oneshot unit with no
# StartTimeoutSec of its own -- a wedged BUNDLE_BIN (a broken symlink, an
# interpreter that hangs on load) must not hang this script, and thus
# boot, forever just to learn its own version.
BUNDLER_VERSION="$(timeout 15 "$BUNDLE_BIN" --version 2>/dev/null | awk '{print $NF}')" || true
export BUNDLER_VERSION

# The running bundler's own REAL gem directory + gemspec, resolved ONCE,
# as root, BEFORE any isolation (review round R5, HIGH #1 -- see
# build_isolated_gem_home below for what this feeds). On this module's
# actual runtime-ruby layout, bundler 2.7.1 is installed as a REGULAR
# gem (stage15.sh: `gem install --local bundler-2.7.1.gem`) ALONGSIDE
# Ruby's own bundled DEFAULT bundler (2.4.19) -- reproduced live: an
# isolated GEM_HOME/GEM_PATH that omits the real bundler-2.7.1 either
# makes `/usr/local/bin/bundle`'s own `Gem.activate_bin_path` silently
# fall back to the WRONG (default, 2.4.19) bundler to run the resolve
# at all, or -- once whichever bundler is running notices the seeded
# Gemfile.lock's real "BUNDLED WITH 2.7.1" and tries to re-exec the
# EXACT locked version -- fails outright with Gem::GemNotFoundException
# ("can't find gem bundler (= 2.7.1) with executable bundle"). Either
# way, an isolated resolve that cannot see its own interpreter is
# broken; every isolated GEM_HOME this script builds (fast path AND
# fallback, review round R5) must also carry a way to find bundler
# itself. `|| true`: a BUNDLER_VERSION this couldn't resolve (empty,
# from the `--version` failure above) must not abort this script either
# -- BUNDLER_GEM_DIR/BUNDLER_GEMSPEC just come out empty, and
# build_isolated_gem_home already tolerates that (its own resolve then
# fails loudly on its own if bundler genuinely can't be found).
if [[ -n "$BUNDLER_VERSION" ]]; then
  BUNDLER_GEM_INFO="$(ruby -e '
    spec = Gem::Specification.find_by_name("bundler", ENV["BUNDLER_VERSION"])
    puts spec.full_gem_path
    puts spec.loaded_from
  ' 2>/dev/null)" || true
fi
BUNDLER_GEM_DIR="$(printf '%s\n' "${BUNDLER_GEM_INFO:-}" | sed -n '1p')"
BUNDLER_GEMSPEC="$(printf '%s\n' "${BUNDLER_GEM_INFO:-}" | sed -n '2p')"
export BUNDLER_GEM_DIR BUNDLER_GEMSPEC

# Isolated per the SECURITY note above: BUNDLE_APP_CONFIG, HOME and
# TMPDIR are all `local -x` — exported for THIS function and its children
# only, never leaking into the rest of this script — and all point under
# a scratch dir this function creates, chowns to $RAILS_USER (review
# round, S3 below), and destroys itself. BUNDLE_PATH is deliberately NOT
# among them (review round, S4 below explains why). Non-fatal on every
# return path; the caller does `relock_gemfile_for_this_node || true`
# under this script's `set -e`.
#
# S3 (review round, SECURITY): the actual resolve below runs AS
# $RAILS_USER via `runuser`, not root. Root only creates/chowns the
# scratch state and does the final compare + atomic swap — it never
# evaluates a gemspec itself. This closes the same class of escalation
# IMP-3731023204f2 closed elsewhere in rails-setup.sh (root evaluating
# something an unprivileged process could influence), applied here to
# the resolve step this script added.
#
# S4 (review round, CORRECTNESS): `bundle lock --local` never consults
# vendor/cache in bundler 2.7.1 -- confirmed by reading cli/lock.rb: it
# calls neither `with_cache!` nor anything cache-related, unlike
# cli/install.rb. Reproduced live: a PATH gem gaining a dependency that
# is already sitting in vendor/cache but absent from the current lock
# makes `bundle lock --local` fail outright ("Could not find gem ... in
# locally installed gems or in gems cached in vendor/cache") even though
# the exact gem it needs is right there. Under BUNDLE_FROZEN=1 (rails-
# start.sh, IMP-094d900f9093 part 2) that failure mode is real: rails
# aborts at boot rather than silently drifting.
#
# FIX: before resolving, register every .gem in vendor/cache as
# "installed" to a throwaway GEM_HOME by extracting JUST its gemspec
# (`Gem::Package.new(f).spec` + `.to_ruby`) into
# GEM_HOME/specifications/ -- no actual gem content extraction, no
# native-extension compilation. Verified live this is sufficient:
# `bundle lock --local` resolves correctly against stub-only
# specifications with no `gems/<name>/` directory behind them at all --
# `bundle lock` never touches a gem's actual content, only its declared
# name/version/deps.
#
# FAST PATH FIRST (review round R4, PERFORMANCE -- this changed the
# shape of the function below): caller 2 means this whole file runs on
# EVERY rails start, not just once per boot, so the common case (nothing
# changed since the image was built) must stay cheap. Try `bundle lock
# --local` first, as $RAILS_USER, against a GEM_HOME/GEM_PATH isolated
# to bundler itself alone (review round R5 -- see "BUNDLER MUST BE
# VISIBLE" below for why this is no longer "no override at all") -- when
# the Gemfile hasn't actually gained a dependency the current lock
# doesn't already satisfy, bundler resolves straight from the seeded
# lock's own already-consistent graph and never needs a real
# installed-gem source at all. Measured live against this module's real,
# ~280-gem production Gemfile.lock: well under a second. Only build the
# vendor/cache stubs, and retry, when that fails.
#
# ONE ruby PROCESS, not one runuser per gem (review round R4,
# PERFORMANCE): the original shape of this fix ran `runuser -u
# $RAILS_USER -- gem spec FILE --ruby` once per cached .gem, serially --
# a real critic measured 1m25s over 325 real .gem files, on EVERY rails
# start once caller 2 existed. A single Ruby process reading every
# `Gem::Package` and writing its `.to_ruby` gemspec is the SAME
# operation, batched: the same critic measured 3.5s over the same 325
# gems. Verified live here (256 real gems from this app's own
# Gemfile.lock): ~71s for the old per-gem loop, ~3s for this one. A gem
# whose package can't be read (reproduced live: a multi-platform gem
# whose selected .gem entry fails `Gem::Package.new(f).spec`'s own
# integrity check) is warned about and skipped, exactly like the old
# per-gem loop's own failure handling -- `bundle lock` will fail loudly
# on its own if something it actually needs was skipped.
#
# The stub GEM_HOME is ROOT-owned, mode 0755, NOT chowned to $RAILS_USER
# (review round R4, SECURITY -- this reopened a symlink-planting risk
# the isolation fix above was supposed to have closed): the previous
# shape ran `runuser -u $RAILS_USER -- gem spec FILE --ruby > "$stub_
# path"` with the REDIRECT's target directory already chowned to
# $RAILS_USER -- root's own shell opened that file for writing, inside a
# directory rails could plant a symlink into moments earlier, which
# would make root's write follow the symlink and truncate whatever it
# pointed at. Root now writes every stub directly, in its own single
# Ruby process, into a directory rails never owns; only the resolve
# itself (below) runs as $RAILS_USER, and it only ever READS from this
# directory.
#
# GEM_PATH is the stub dir ALONE for this fallback resolve -- NOT
# `$gem_stub_dir:$real_gem_path` (review round R4, CORRECTNESS -- this
# reverses this function's own prior shape, and the reason matters): a
# critic reproduced a dependency (`matrix`) that was resolvable from
# this MACHINE's real, ambient Gem.path but genuinely ABSENT from
# vendor/cache. With the real path appended, the fallback resolve
# happily pinned it into Gemfile.lock -- then a REAL, frozen `bundle
# install --local` against vendor/cache alone (exactly what rails does
# at boot) failed, because nothing on the actual deployed node can ever
# supply a gem this way; the appliance's own ambient Gem.path only ever
# contains what THIS SAME vendor/cache installed at build time, so
# anything the fallback needs must come from vendor/cache or not at all.
# Reproduced and fixed live: with GEM_PATH narrowed to the stub dir
# alone, the same scenario now fails LOUD, at relock time, instead of
# quietly shipping a lock that crash-loops rails later. Ruby's own
# default gems (bundled with the interpreter, e.g. psych, date) are
# still found regardless of GEM_PATH, so this loses nothing legitimate.
#
# BUNDLER MUST BE VISIBLE TOO -- in BOTH isolated homes, not just the
# fallback's (review round R5, HIGH #1, a second critic against this
# module's REAL runtime-ruby gem layout): narrowing GEM_PATH to "the
# stub dir alone" ALSO hides bundler-2.7.1 itself, since it is a regular
# installed gem there, not a Ruby default gem (stage15.sh: `gem install
# --local bundler-2.7.1.gem`, alongside Ruby's own bundled default,
# 2.4.19). Reproduced live: an isolated resolve that can't see
# bundler-2.7.1 either silently runs under the WRONG (default, 2.4.19)
# bundler, or -- once that bundler notices the seeded lock's real
# "BUNDLED WITH 2.7.1" and tries to re-exec the exact locked version --
# fails outright (Gem::GemNotFoundException, "can't find gem bundler
# (= 2.7.1) with executable bundle"). This is the ORIGINAL S1
# crash-loop (part 1's review) resurfacing through a different door: an
# isolated GEM_HOME/GEM_PATH that hides the interpreter running the
# resolve is just as broken as one that hides a real dependency.
# `build_isolated_gem_home` (below) registers the SAME real bundler
# (BUNDLER_GEM_DIR/BUNDLER_GEMSPEC, resolved once as root before any
# isolation -- see this file's top) into EVERY isolated GEM_HOME this
# script builds now: a bundler-only one for the fast path, and
# bundler-plus-stubs for the fallback (see "FAST PATH FIRST" above and
# relock_gemfile_for_this_node's own comment for where each is built).
# This also means the fast path is no longer "no override at all" --
# see that paragraph's own update.
#
# BUNDLED WITH drift (review round R4, follow-up to the above): before
# the fix directly above, narrowing GEM_PATH meant bundler itself was no
# longer "installed" anywhere the resolve could see, and
# `Bundler.bundler_version_to_lock` silently fell back to Ruby's bundled
# DEFAULT bundler gem (2.4.19) instead of the one actually running here
# -- reproduced live, and NOT fixed by also passing `bundle lock
# --bundler=<version>` (verified live: that flag does not override this
# fallback for a plain, non-`--update` lock once bundler itself is
# unresolvable). `pin_bundled_with` still rewrites the "BUNDLED WITH"
# line to the ACTUAL running `bundle --version` deterministically, after
# every resolve, fast-path or fallback alike, as a second, independent
# safety net -- a no-op once bundler is genuinely resolvable in both
# isolated homes (review round R5), but kept rather than removed: it
# costs nothing and does not depend on BUNDLER_GEM_DIR/BUNDLER_GEMSPEC
# having resolved correctly.
#
# Native-extension gems are not dropped from the stub index (review
# round R4, NIT): for any cached gem whose gemspec declares
# `extensions` (a C/native-extension gem), the stub step also touches
# `GEM_HOME/extensions/<platform>/<api-version>/<full-name>/
# gem.build_complete` -- the marker RubyGems' own installed-gem
# machinery uses to consider a gem's extensions already built. `bundle
# lock` did not measurably need this in testing (it never loads or
# builds anything), but it is a cheap defensive match for the real,
# fully-installed layout on the off chance a future bundler version
# checks it during resolution too.
#
# BUNDLE_PATH is deliberately NOT set for the resolve below (a change
# from this function's pre-review-round shape, which did set it under
# $scratch) -- verified live it actively BREAKS gem visibility here:
# with BUNDLE_PATH pointed at an empty scratch dir, Bundler treats that
# as the definitive "installed gems" location and ignores GEM_HOME/
# GEM_PATH entirely, so even a gem the stub step just registered reads
# as "not found". `bundle lock` never installs anything, so it never
# needs a real BUNDLE_PATH; leaving it unset falls back to Bundler's
# default (Bundler.root/vendor/bundle, i.e. $RAILS_DIR/vendor/bundle) as
# an inert config value `bundle lock` never actually reads content from.
#
# The final swap is through a FRESH, root-created temp file, never the
# rails-touched one directly (review round R4, NIT/defense-in-depth):
# the resolve itself, fast-path or fallback, still runs the bundler
# PROCESS as $RAILS_USER (S3 above) against a lockfile living under a
# $RAILS_USER-owned scratch tree (S3's own isolation) -- that lockfile's
# INODE has been written to by rails throughout. Once root has the
# resolved content, it is `cp`'d into a brand-new temp file root itself
# created directly in $RAILS_DIR (never chowned to anyone else, never
# opened by the runuser'd process), chmod/chown'd to match the real
# Gemfile.lock, and THAT file is `mv -f`'d into place. The rails-touched
# temp file is discarded, unused for the swap.
# attempt_bundle_lock, build_gem_stubs, build_isolated_gem_home: called
# from BOTH this script's own process (never, actually -- see
# relock_gemfile_for_this_node's own comment) and from the
# `timeout`-wrapped child process it re-execs into, hence `export -f`
# below rather than plain function defs. All three read
# BUNDLE_APP_CONFIG/HOME/TMPDIR/POWERNODE_DEPLOYED/BUNDLER_VERSION/
# BUNDLER_GEM_DIR/BUNDLER_GEMSPEC from the environment (this file's top,
# and relock_gemfile_for_this_node's own `local -x`) rather than taking
# them as arguments -- an exported function only carries its OWN body
# across the fork, never the caller's local variables, so anything it
# needs must already be an environment variable by the time `timeout`
# starts the child.
#
# gem_home is NEVER empty anymore (review round R5 -- reverses R4's own
# "" meant no override at all): both the fast path and the fallback now
# call this against a REAL, isolated GEM_HOME/GEM_PATH --
# build_isolated_gem_home's own bundler-only home for the fast path, and
# that same mechanism layered onto the vendor/cache stub dir for the
# fallback (see this file's header, "BUNDLER MUST BE VISIBLE TOO", and
# relock_gemfile_for_this_node's own comment for where each is built).
attempt_bundle_lock() {
  local lockfile="$1" gem_home="$2"
  local -a lock_args=(lock --local --lockfile="$lockfile")
  # R5 item 4: an empty BUNDLER_VERSION (the `--version` probe above
  # failed, or a test's stub BUNDLE_BIN doesn't implement it) must not
  # become a literal `--bundler=` -- bundler treats a blank argument as
  # a real (and invalid) requested version, not "no preference", same
  # reason pin_bundled_with already guards on this.
  if [[ -n "$BUNDLER_VERSION" ]]; then
    lock_args+=(--bundler="$BUNDLER_VERSION")
  fi
  runuser -u "$RAILS_USER" -- env \
    BUNDLE_GEMFILE="$BUNDLE_GEMFILE" \
    BUNDLE_APP_CONFIG="$BUNDLE_APP_CONFIG" \
    HOME="$HOME" \
    TMPDIR="$TMPDIR" \
    POWERNODE_DEPLOYED=1 \
    GEM_HOME="$gem_home" \
    GEM_PATH="$gem_home" \
    "$BUNDLE_BIN" "${lock_args[@]}"
}

# Stub-registers every .gem in vendor/cache into $1 (a ROOT-owned,
# mode-0755 GEM_HOME -- see this file's header) in ONE Ruby process, as
# root -- never as $RAILS_USER, and never one process per gem (see this
# file's header for both). A gem whose package can't be read is warned
# about and skipped, same as `bundle lock` itself would report if
# something it actually needed was missing.
build_gem_stubs() {
  local gem_stub_dir="$1"
  local -a cache_gems
  shopt -s nullglob
  cache_gems=("$RAILS_DIR"/vendor/cache/*.gem)
  shopt -u nullglob
  if [[ ${#cache_gems[@]} -eq 0 ]]; then
    return 0
  fi
  ruby -e '
    require "rubygems/package"
    require "fileutils"
    dir = ARGV.shift
    specs_dir = File.join(dir, "specifications")
    ARGV.each do |f|
      begin
        s = Gem::Package.new(f).spec
        File.write(File.join(specs_dir, "#{s.full_name}.gemspec"), s.to_ruby)
        next if s.extensions.nil? || s.extensions.empty?
        ext_dir = File.join(dir, "extensions", Gem::Platform.local.to_s, Gem.extension_api_version, s.full_name)
        FileUtils.mkdir_p(ext_dir)
        FileUtils.touch(File.join(ext_dir, "gem.build_complete"))
      rescue => e
        warn "[rails-relock-gemfile] WARNING: could not read #{File.basename(f)}'"'"'s spec from vendor/cache -- continuing without it (#{e.class}: #{e.message})"
      end
    end
  ' "$gem_stub_dir" "${cache_gems[@]}"
}

# Registers the SAME real, running bundler (BUNDLER_GEM_DIR/
# BUNDLER_GEMSPEC, resolved once as root before any isolation -- see
# this file's top) into $1 -- review round R5, HIGH #1, see this file's
# header, "BUNDLER MUST BE VISIBLE TOO". A SYMLINK to bundler's real gem
# dir, never a copy (bundler's own lib tree is sizeable, and this dir
# gets rm -rf'd on every call); a plain `cp` of just its gemspec, so
# Gem::Specification.all sees it as "locally installed" the same way
# build_gem_stubs's own stubs do. Idempotent (specifications/gems
# already existing is fine); a silent no-op if BUNDLER_GEM_DIR/
# BUNDLER_GEMSPEC never resolved -- the resolve this feeds then fails
# loudly on its own ("can't find gem bundler"), which is the correct,
# non-silent outcome for that case, not a reason to error here too.
build_isolated_gem_home() {
  local dir="$1"
  mkdir -p "$dir/specifications" "$dir/gems"
  if [[ -n "${BUNDLER_GEM_DIR:-}" && -n "${BUNDLER_GEMSPEC:-}" && -d "$BUNDLER_GEM_DIR" && -f "$BUNDLER_GEMSPEC" ]]; then
    ln -sfn "$BUNDLER_GEM_DIR" "$dir/gems/$(basename "$BUNDLER_GEM_DIR")"
    cp "$BUNDLER_GEMSPEC" "$dir/specifications/"
  fi
}
export -f attempt_bundle_lock build_gem_stubs build_isolated_gem_home

# Rewrites the lockfile's own "BUNDLED WITH" line to the version this
# script is ACTUALLY running (see this file's header, "BUNDLED WITH
# drift") -- a no-op when it was already correct.
pin_bundled_with() {
  local lockfile="$1"
  [[ -n "$BUNDLER_VERSION" ]] || return 0
  awk -v version="$BUNDLER_VERSION" '
    /^BUNDLED WITH$/ { print; getline; print "   " version; next }
    { print }
  ' "$lockfile" > "$lockfile.bundled-with-pin" && mv "$lockfile.bundled-with-pin" "$lockfile"
}

relock_gemfile_for_this_node() {
  local scratch tmp_lockfile final_tmp before after

  if ! scratch="$(mktemp -d)"; then
    echo "[rails-relock-gemfile] WARNING: could not create a scratch dir for the Gemfile.lock re-lock -- skipping" >&2
    return 1
  fi
  if ! tmp_lockfile="$(mktemp "$RAILS_DIR/Gemfile.lock.relock.XXXXXX")"; then
    echo "[rails-relock-gemfile] WARNING: could not create a temp lockfile under $RAILS_DIR -- skipping the Gemfile.lock re-lock" >&2
    rm -rf "$scratch"
    return 1
  fi
  # Cleans up on EVERY return below -- success, an early failure, or
  # `timeout` killing bundler partway through. `final_tmp` is unset on
  # most return paths (the `${final_tmp:-}` default keeps that from
  # tripping this file's own `set -u`... except this file does not set
  # `-u`; kept anyway as documentation of intent). Both `rm -f` targets
  # are no-ops once the success path below has already `mv -f`'d
  # `final_tmp` away -- `tmp_lockfile` itself is NEVER renamed anymore
  # (review round R4, see this file's header, "The final swap is
  # through a FRESH, root-created temp file"), so it must always be
  # cleaned up here explicitly rather than relying on a rename to
  # consume it.
  trap 'rm -rf "$scratch"; rm -f "$tmp_lockfile" "${final_tmp:-}"' RETURN

  local -x BUNDLE_APP_CONFIG="$scratch/bundle-config"
  local -x HOME="$scratch/home"
  local -x TMPDIR="$scratch/tmp"
  local -x POWERNODE_DEPLOYED=1
  mkdir -p "$BUNDLE_APP_CONFIG" "$HOME" "$TMPDIR"

  before="$(path_gems_in_lock || true)"

  # SEED the temp lockfile from the CURRENT lock before resolving (HIGH
  # #2, see this file's header) -- `cp -p` preserves mode/ownership too,
  # which mostly closes HIGH #1 as a side effect (the explicit
  # chmod/chown --reference below still runs regardless, in case
  # bundler's own write recreates rather than truncates the file).
  if ! cp -p "$RAILS_DIR/Gemfile.lock" "$tmp_lockfile"; then
    echo "[rails-relock-gemfile] WARNING: could not seed the temp lockfile from the current Gemfile.lock -- skipping the Gemfile.lock re-lock" >&2
    return 1
  fi

  # S3: everything under $scratch (including the temp lockfile, which
  # root created via mktemp above) must be writable by $RAILS_USER for
  # the runuser'd steps below. This scratch tree is DELIBERATELY
  # separate from the stub GEM_HOME the fallback path below creates for
  # itself (review round R4, SECURITY) -- that one stays root-owned and
  # is never touched by this chown.
  if ! chown -R "$RAILS_USER:$RAILS_USER" "$scratch" "$tmp_lockfile"; then
    echo "[rails-relock-gemfile] WARNING: could not chown the scratch env to $RAILS_USER -- skipping the Gemfile.lock re-lock" >&2
    return 1
  fi

  # ONE timeout for the ENTIRE resolve -- fast path AND, only if that
  # fails, the vendor/cache stub build AND the retry (review round R4,
  # PERFORMANCE; see this file's header, "`timeout 120`"). This runs as
  # a single `bash -c` child so `timeout` can bound the whole sequence
  # at once, rather than three separately-timed subprocess calls that
  # could individually stay under budget while their SUM does not.
  # `export -f` above is what lets this fresh child process see
  # attempt_bundle_lock/build_gem_stubs/build_isolated_gem_home at all;
  # BUNDLE_APP_CONFIG/HOME/TMPDIR/POWERNODE_DEPLOYED reach it the same
  # way, via the `local -x` exports above (still in scope for every
  # child forked from here).
  #
  # `TMPDIR=/tmp mktemp -d`, NOT bare `mktemp -d` (review round R5,
  # SECURITY item 3): bare `mktemp -d` here would honor the INHERITED
  # TMPDIR ($scratch/tmp, exported by `local -x` above) -- a directory
  # already chowned to $RAILS_USER a few lines up. A $RAILS_USER process
  # could rename that directory away and plant a symlink in its place
  # between this mktemp call and root's own writes into it
  # (build_isolated_gem_home's `ln`/`cp`, build_gem_stubs's Ruby
  # process), and root would then write through the symlink. The real
  # system /tmp is sticky-bit protected (only the creating user, or
  # root, can rename/unlink an entry there regardless of that entry's
  # own mode) and mktemp's own mkdtemp(3) call is still atomic and
  # unpredictably named, so this closes the race without needing a
  # bespoke root-owned scratch root of its own.
  if ! timeout -k 10 120 bash -c '
    set -euo pipefail
    tmp_lockfile="$1"

    bundler_only_home="$(TMPDIR=/tmp mktemp -d)"
    chmod 0755 "$bundler_only_home"
    build_isolated_gem_home "$bundler_only_home"

    if attempt_bundle_lock "$tmp_lockfile" "$bundler_only_home"; then
      echo "[rails-relock-gemfile] fast path (bundler-isolated, no vendor/cache stubs) resolved successfully" >&2
      rm -rf "$bundler_only_home"
      exit 0
    fi
    rm -rf "$bundler_only_home"

    echo "[rails-relock-gemfile] fast path resolve failed -- composition likely changed since build; building vendor/cache gemspec stubs" >&2

    gem_stub_dir="$(TMPDIR=/tmp mktemp -d)"
    chmod 0755 "$gem_stub_dir"
    mkdir -p "$gem_stub_dir/specifications"
    build_gem_stubs "$gem_stub_dir"
    build_isolated_gem_home "$gem_stub_dir"

    status=0
    attempt_bundle_lock "$tmp_lockfile" "$gem_stub_dir" || status=$?
    rm -rf "$gem_stub_dir"
    exit "$status"
  ' _ "$tmp_lockfile"; then
    echo "[rails-relock-gemfile] WARNING: bundle lock --local failed or timed out (both the fast path and, if attempted, the vendor/cache stub fallback) -- Gemfile.lock may still disagree with this node's extension composition" >&2
    return 1
  fi

  pin_bundled_with "$tmp_lockfile"

  if cmp -s "$tmp_lockfile" "$RAILS_DIR/Gemfile.lock" 2>/dev/null; then
    echo "[rails-relock-gemfile] Gemfile.lock already matches this node's extension composition -- not re-locking"
    return 0
  fi

  # The final swap is through a FRESH, root-created temp file, never
  # $tmp_lockfile itself (review round R4, see this file's header) --
  # $tmp_lockfile's inode has been written to by the runuser'd bundler
  # process throughout; copy its RESOLVED CONTENT into a new file root
  # creates directly, then treat that new file the way HIGH #1 always
  # has (match the real Gemfile.lock's mode/owner before the swap).
  if ! final_tmp="$(mktemp "$RAILS_DIR/Gemfile.lock.relock-final.XXXXXX")"; then
    echo "[rails-relock-gemfile] WARNING: could not create the final root-owned temp lockfile -- Gemfile.lock is unchanged" >&2
    return 1
  fi
  if ! cp "$tmp_lockfile" "$final_tmp"; then
    echo "[rails-relock-gemfile] WARNING: could not copy the resolved lock into a root-owned temp file -- Gemfile.lock is unchanged" >&2
    return 1
  fi
  chmod --reference="$RAILS_DIR/Gemfile.lock" "$final_tmp" 2>/dev/null || chmod 0644 "$final_tmp"
  chown --reference="$RAILS_DIR/Gemfile.lock" "$final_tmp" 2>/dev/null || true

  if ! mv -f "$final_tmp" "$RAILS_DIR/Gemfile.lock"; then
    echo "[rails-relock-gemfile] WARNING: bundle resolved a new Gemfile.lock but could not install it (mv failed) -- Gemfile.lock is unchanged" >&2
    return 1
  fi
  after="$(path_gems_in_lock || true)"
  echo "[rails-relock-gemfile] re-locked Gemfile.lock for this node's extension composition. PATH gems before:"
  echo "${before:-<none>}" | sed 's/^/[rails-relock-gemfile]   /'
  echo "[rails-relock-gemfile] PATH gems after:"
  echo "${after:-<none>}" | sed 's/^/[rails-relock-gemfile]   /'
}

relock_gemfile_for_this_node || true
