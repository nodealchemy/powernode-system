// confinement_probe.go is round Y's stateless replacement for X1's persisted
// pending-confinement set (IMP-caef5c00d63f — see design section on the
// round-X confirm review's N1/N2/N3/N4/N5 findings, and reconcile.go's own
// doc on where this is wired into RunOnce).
//
// THE SHAPE. Instead of remembering, across ticks, which units a PAST write
// changed and whether that change ever reached the running process (X1's
// own persisted set — the thing that could never clear on a self-hosted
// node, N1's root cause), this file RE-DERIVES the fact every single tick,
// straight from the kernel: read the running unit's OWN effective
// capability sets from /proc/<pid>/status and compare them against what the
// manifest currently declares. There is nothing to carry forward and
// nothing that needs "un-stamping" to force a retry — a unit that is
// genuinely stale reads as stale on THIS tick and on every tick after,
// independent of what any earlier tick did or failed to do, until an
// operator restart or a recompose actually changes what is running.
//
// STALENESS PREDICATE (acceptance-level, not clock/mtime-based — see the
// design's own rejection of ActiveEnterTimestamp/mtime comparisons: boot
// compose can write drop-ins before NTP has run, and identical-byte
// rewrites never touch mtime at all).
//
//	declared  := CapabilityMask(unitAllow[u])          // the writer's own resolved list
//	probed    := ActiveState == "active" && MainPID > 0 && /proc/<MainPID>/status readable
//	stale(u)  := probed && (CapBnd != declared || (CapAmb &^ declared) != 0)
//	wider(u)  := probed && ((CapBnd &^ declared) != 0 || (CapAmb &^ declared) != 0)
//
// Bounding is compared EXACTLY (it is the ceiling — systemd's
// CapabilityBoundingSet=<list> drops every other bit, so an empty list
// gives CapBnd=0 and the full set gives every bit). Ambient is compared as
// a SUBSET check so a root-run unit (where ambient is irrelevant) never
// false-positives, while a legacy ambient-capabilities.conf grant wider
// than declared still shows.
//
// wider(), not stale(), gates a restart: a running set can never be WIDER
// than what systemd applied at exec, so a wider process is by construction
// one that started under an OLDER, wider drop-in — exactly the crash-mid-
// tick / failed-restart / withheld-under-unknown residue N3 and round W
// lost. A unit that is merely narrower than declared (a widening change
// whose restart was lost) is report-only: it heals on the next restart of
// ANY kind, and restarting a unit that has self-narrowed its OWN bounding
// set is not a security gap to correct.
package runtime

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/systemd"
)

// procRoot is a seam so tests can point the probe at a temp directory
// carrying fake "<pid>/status" files instead of the real /proc.
var procRoot = "/proc"

// nowForConfinementBackoff is a seam so R2's own 15-minute backoff is
// testable without a real wall-clock wait — mirrors nowForUpgradeBackoff's
// own established pattern in this package (upgrade.go).
var nowForConfinementBackoff = time.Now

// levelRestartBackoff is R2's own per-unit cooldown after issuing (or
// attempting) a level-triggered restart — see Reconciler.levelRestartAt's
// own doc for why losing this state can only delay a restart, never cause
// one.
const levelRestartBackoff = 15 * time.Minute

// unitConfinement is one unit's probed-vs-declared capability comparison
// for a single tick. Zero value (Probed=false) means "nothing to compare" —
// inactive, not found, RemainAfterExit with no live MainPID, or a
// systemctl/proc read that itself failed — and both stale() and wider()
// are false for it, never true by default.
type unitConfinement struct {
	Unit       string
	Active     bool
	MainPID    int
	NeedReload bool
	Probed     bool
	RunningBnd uint64
	RunningAmb uint64
	Declared   uint64
	Err        error
}

// stale reports whether the running process's effective capabilities
// diverge from the manifest's current declaration in EITHER direction
// (wider OR narrower).
func (u unitConfinement) stale() bool {
	return u.Probed && (u.RunningBnd != u.Declared || (u.RunningAmb&^u.Declared) != 0)
}

// wider reports whether the running process holds MORE than the manifest
// currently declares — the only direction R2 ever restarts for. See this
// file's own top-of-file doc for why narrower is report-only.
func (u unitConfinement) wider() bool {
	return u.Probed && ((u.RunningBnd&^u.Declared) != 0 || (u.RunningAmb&^u.Declared) != 0)
}

// declaredCapMasks resolves module mod's own per-unit capability ceiling
// straight from decideModuleSecurityPolicy — NOT decideSecurityPolicyForAttach,
// which additionally emits a K5b unknown-capability-name OnError warning on
// every call; that warning belongs to the ATTACH path (once per genuine
// change), and calling it from here would repeat the same warning every
// single tick for as long as a stale/legacy manifest keeps naming an
// unrecognized capability, for a function that isn't writing anything.
//
// Returns ok=false for a privileged module (no drop-in, no ceiling to
// compare against — see security_dropins.go's own privileged skip) or a
// policy-decision error (refused elsewhere already; nothing here to add).
func (r *Reconciler) declaredCapMasks(mod mount.Module, mf *manifest.Manifest) (masks map[string]uint64, ok bool) {
	policy, unitAllow, _, err := decideModuleSecurityPolicy(mod, mf, r.privilegedAllow, true, attachCapabilityWrites)
	if err != nil || policy == nil || policy.Privileged {
		return nil, false
	}
	masks = make(map[string]uint64, len(unitAllow))
	for unit, allow := range unitAllow {
		mask, err := security.CapabilityMask(allow)
		if err != nil {
			// An unknown capability name is already reported by the ATTACH
			// path's own K5b warning; this pass simply has nothing to
			// compare that unit against and skips it rather than treating
			// an unparseable ceiling as either stale or clean.
			continue
		}
		masks[unit] = mask
	}
	return masks, true
}

// readProcCapSets reads CapBnd/CapAmb from /proc/<pid>/status (under
// procRoot, the test seam). Both fields are always present on a real
// kernel; their absence here means the process vanished mid-read or
// procRoot points at an incomplete fixture — either way, an error, never a
// zero-value guess.
func readProcCapSets(pid int) (bnd, amb uint64, err error) {
	path := filepath.Join(procRoot, strconv.Itoa(pid), "status")
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, 0, err
	}
	var haveBnd, haveAmb bool
	for _, line := range strings.Split(string(data), "\n") {
		switch {
		case strings.HasPrefix(line, "CapBnd:"):
			if bnd, err = security.ParseProcCapMask(strings.TrimPrefix(line, "CapBnd:")); err != nil {
				return 0, 0, fmt.Errorf("%s: CapBnd: %w", path, err)
			}
			haveBnd = true
		case strings.HasPrefix(line, "CapAmb:"):
			if amb, err = security.ParseProcCapMask(strings.TrimPrefix(line, "CapAmb:")); err != nil {
				return 0, 0, fmt.Errorf("%s: CapAmb: %w", path, err)
			}
			haveAmb = true
		}
	}
	if !haveBnd || !haveAmb {
		return 0, 0, fmt.Errorf("%s: missing CapBnd/CapAmb", path)
	}
	return bnd, amb, nil
}

// probeUnitConfinement reads unit's current ActiveState/MainPID/
// NeedDaemonReload in one systemctl call, then — only when the unit is
// active with a live MainPID — reads that process's own effective
// capability sets. Every other case (inactive, not-found/renamed,
// RemainAfterExit with MainPID=0, a systemctl or /proc read that itself
// errors) returns Probed=false: "nothing running to be stale", never a
// guessed answer.
func (r *Reconciler) probeUnitConfinement(ctx context.Context, unit string, declared uint64) unitConfinement {
	uc := unitConfinement{Unit: unit, Declared: declared}
	props, err := systemd.ShowProperties(ctx, r.cfg.MountRunner, unit, "ActiveState", "MainPID", "NeedDaemonReload")
	if err != nil {
		uc.Err = err
		return uc
	}
	uc.Active = props["ActiveState"] == "active"
	uc.NeedReload = props["NeedDaemonReload"] == "yes"
	pid, _ := strconv.Atoi(strings.TrimSpace(props["MainPID"]))
	uc.MainPID = pid
	if !uc.Active || pid <= 0 {
		return uc
	}
	bnd, amb, err := readProcCapSets(pid)
	if err != nil {
		// The process answered is-active a moment ago but /proc no longer
		// has it (exited between the two reads) — not an error worth
		// surfacing, just nothing to compare this tick.
		uc.Err = err
		return uc
	}
	uc.RunningBnd, uc.RunningAmb, uc.Probed = bnd, amb, true
	return uc
}

// reconcileStaleConfinement (round Y) is this file's own entry point,
// called once per RunOnce pass (reconcile.go, right after
// reconfirmConfinementIfNeeded) over every currently attached, N4-eligible
// module's own units. Publishes the tick's own complete stale set in ONE
// atomic Store at the end, mirroring publishSecurityFailClosed's own
// pattern — a concurrent heartbeat read never sees a half-built set.
func (r *Reconciler) reconcileStaleConfinement(ctx context.Context, current *mount.State, manifests map[string]*manifest.Manifest) {
	var staleUnits []string
	for _, mod := range current.AttachedModules {
		mf, ok := manifests[mod.ID]
		if !ok {
			continue
		}
		// N4: identical gate to reconfirmConfinementIfNeeded's own — a
		// module mid-upgrade is compared against nothing here either; its
		// drop-ins are actively in flux and a probe against either the old
		// OR the new ceiling would be answering a question that is not
		// settled yet.
		if mod.PendingDigest != "" || mf.Digest != mod.Digest {
			continue
		}
		masks, ok := r.declaredCapMasks(mod, mf)
		if !ok {
			continue
		}
		for _, unit := range mf.UnitNames() {
			declared, ok := masks[unit]
			if !ok {
				// Privileged units take no capability drop-in by design
				// (security_dropins.go) and so have no entry here — never
				// probed, matching the attach path's own skip.
				continue
			}
			uc := r.probeUnitConfinement(ctx, unit, declared)
			if !uc.stale() {
				continue
			}
			staleUnits = append(staleUnits, unit)
			r.handleStaleUnit(ctx, mod, uc)
		}
	}
	sort.Strings(staleUnits)
	r.confinementStaleUnits.Store(&staleUnits)
}

// handleStaleUnit is reconcileStaleConfinement's own per-unit disposition:
// report always; restart (R2) only when wider, only when restartPermitted
// (never on Yes/Unknown — invariant 1), and only outside the per-unit
// backoff.
func (r *Reconciler) handleStaleUnit(ctx context.Context, mod mount.Module, uc unitConfinement) {
	if !uc.wider() {
		r.cfg.OnError("reconciler:confinement_stale", fmt.Errorf(
			"module %s: unit %s's running capabilities are NARROWER than its current manifest declares (bounding running=%#x declared=%#x) — self-narrowing is not a gap, report only; heals on the unit's own next restart of any kind",
			mod.ID, uc.Unit, uc.RunningBnd, uc.Declared))
		return
	}
	if !r.restartPermitted() {
		r.cfg.OnError("reconciler:confinement_stale", fmt.Errorf(
			"module %s: unit %s's running capabilities are WIDER than its current manifest declares (bounding running=%#x declared=%#x, ambient extra=%#x) but this node is self-hosted (or restart is not positively confirmed safe) — restart deliberately withheld (rule 1); schedule `systemctl restart %s` or wait for the next recompose",
			mod.ID, uc.Unit, uc.RunningBnd, uc.Declared, uc.RunningAmb&^uc.Declared, uc.Unit))
		return
	}
	if until, backedOff := r.levelRestartBackoffActive(uc.Unit); backedOff {
		r.cfg.OnError("reconciler:confinement_stale", fmt.Errorf(
			"module %s: unit %s's running capabilities are WIDER than declared; a level-triggered restart already ran recently and is backed off until %s",
			mod.ID, uc.Unit, until.Format(time.RFC3339)))
		return
	}
	r.markLevelRestartAttempt(uc.Unit)
	if uc.NeedReload {
		if err := systemd.DaemonReload(ctx, r.cfg.MountRunner); err != nil {
			r.noteUnconverged("reconciler:confinement_restart_failed", mod.ID, fmt.Errorf(
				"module %s: unit %s: daemon-reload before its level-triggered restart failed: %w", mod.ID, uc.Unit, err))
			return
		}
	}
	if err := systemd.Action(ctx, r.cfg.MountRunner, uc.Unit, systemd.Restart); err != nil {
		r.noteUnconverged("reconciler:confinement_restart_failed", mod.ID, fmt.Errorf(
			"module %s: unit %s: level-triggered restart (R2, wider than declared) failed: %w", mod.ID, uc.Unit, err))
		return
	}
	r.cfg.OnError("reconciler:confinement_stale", fmt.Errorf(
		"module %s: unit %s's running capabilities were WIDER than declared (bounding running=%#x declared=%#x) — level-triggered restart issued",
		mod.ID, uc.Unit, uc.RunningBnd, uc.Declared))
}

// levelRestartBackoffActive reports whether unit is still within its
// 15-minute post-restart cooldown, and the instant it clears.
func (r *Reconciler) levelRestartBackoffActive(unit string) (until time.Time, active bool) {
	last, ok := r.levelRestartAt[unit]
	if !ok {
		return time.Time{}, false
	}
	until = last.Add(levelRestartBackoff)
	return until, nowForConfinementBackoff().Before(until)
}

// markLevelRestartAttempt records THIS instant as unit's own last
// level-restart attempt — called BEFORE the restart itself, deliberately:
// a restart this call issues but which then FAILS must still start the
// backoff clock (an immediate retry against a unit whose restart just
// failed is not a recovery strategy this narrow self-heal is meant to
// provide; the ordinary edge/manual paths remain available regardless).
func (r *Reconciler) markLevelRestartAttempt(unit string) {
	if r.levelRestartAt == nil {
		r.levelRestartAt = make(map[string]time.Time)
	}
	r.levelRestartAt[unit] = nowForConfinementBackoff()
}

// ConfinementStaleUnits returns the units the most recently COMPLETED
// reconcileStaleConfinement pass found stale (either direction), for
// buildHeartbeat's own HeartbeatPayload.RuntimeConfinementStaleUnits field.
// nil/empty means none. Recomputed from scratch every tick — never
// persisted to state.json, so a fresh agent process simply reports nothing
// here until its own first pass runs.
func (r *Reconciler) ConfinementStaleUnits() []string {
	if p := r.confinementStaleUnits.Load(); p != nil {
		return *p
	}
	return nil
}
