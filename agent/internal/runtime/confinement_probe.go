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
// WIDENING PREDICATE (acceptance-level, not clock/mtime-based — see the
// design's own rejection of ActiveEnterTimestamp/mtime comparisons: boot
// compose can write drop-ins before NTP has run, and identical-byte
// rewrites never touch mtime at all).
//
//	declared  := CapabilityMask(unitAllow[u])
//	probed    := ActiveState == "active" && MainPID > 0 && /proc/<MainPID>/status readable
//	wider(u)  := probed && ((CapBnd &^ declared) != 0 || (CapAmb &^ declared) != 0)
//
// ROUND Z (Z3): WIDER is the only direction this pass ever acts on —
// narrower-than-declared is SILENT, not even reported. Round Y (and Z1)
// used to report a narrower finding too (report-only, since it was never
// actionable); Z3 removes that entirely: a self-narrowed process is not a
// security-relevant fact worth a log line every tick, and folding "stale"
// (either direction) and "wider" into one predicate removes a distinction
// nothing downstream of this pass ever needed once R2 (the restart) itself
// was already gone (Z1).
//
// ROUND Z (Z7): Z3 also shipped a declared/cap_last_cap intersection
// (declared masked to /proc/sys/kernel/cap_last_cap before the compare),
// reasoning that a capability the running kernel does not implement should
// never count toward a widening finding. Deleted here: reviewer A proved
// it is provably inert given the invariant above — the kernel can never
// report a CapBnd/CapAmb bit beyond its own cap_last_cap in the first
// place (/proc always reports a kernel-bounded value), so removing that
// same bit from `declared` can never change `CapBnd &^ declared` or the
// ambient equivalent. Confirmed independently before deleting it: no test
// in the suite depended on the intersection being present.
//
// Bounding is compared EXACTLY (it is the ceiling — systemd's
// CapabilityBoundingSet=<list> drops every other bit, so an empty list
// gives CapBnd=0 and the full set gives every bit). Ambient is compared as
// a SUBSET check so a root-run unit (where ambient is irrelevant) never
// false-positives, while a legacy ambient-capabilities.conf grant wider
// than declared still shows.
//
// ROUND Z (Z1): this pass is PURELY DIAGNOSTIC — it never restarts,
// reloads or stops anything, on ANY node type. Round Y's own R2 (a
// level-triggered restart for a unit found wider than declared) is
// DELETED: reviewer A found it could loop forever on a unit whose drop-in
// write itself keeps failing closed — the restart never fixes anything
// (the on-disk drop-in never actually changed), so R2 just restarted the
// same service every backoff interval, permanently, for a condition R2
// itself had no way to resolve. The only restart mechanism left in this
// package is R1 (attachModuleServicesOpts' own edge-triggered restart,
// gated on restartPermitted, fired only when THIS tick's own drop-in
// write actually changed bytes) — see reconcile.go's own doc on
// attachModuleServices for that path. A unit this pass finds wider is
// reported every tick for as long as it stays wider; recovering it is an
// operator action (`systemctl restart <unit>`) or the unit's own next
// recompose, never something this pass does for you.
package runtime

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/systemd"
)

// procRoot is a seam so tests can point the probe at a temp directory
// carrying fake "<pid>/status" files instead of the real /proc.
var procRoot = "/proc"

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

// wider reports whether the running process holds MORE than the manifest
// currently declares — the ONLY direction this pass acts on at all (round
// Z, Z3: narrower is silent — see this file's own top-of-file doc).
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
			if uc.Err != nil {
				// Round Z (Z6, reviewer A, LOW): a probe failure (systemctl
				// show itself erroring, or /proc vanishing between the
				// is-active read and the status read) used to be dropped
				// silently — uc.Err set, Probed stays false, wider() reads
				// false, and the loop just moved on. A unit that IS wider
				// this tick would then go completely unreported, with no
				// signal that anything was even checked. Report-only, same
				// as every other channel in this file — this pass cannot
				// restart anything regardless, so a probe failure is not a
				// converge-blocking condition, only a visibility one.
				r.cfg.OnError("reconciler:confinement_probe_failed", fmt.Errorf(
					"module %s: unit %s: could not verify running confinement this tick: %w", mod.ID, unit, uc.Err))
				continue
			}
			if !uc.wider() {
				continue
			}
			staleUnits = append(staleUnits, unit)
			r.handleStaleUnit(mod, uc)
		}
	}
	sort.Strings(staleUnits)
	r.confinementStaleUnits.Store(&staleUnits)
}

// handleStaleUnit is reconcileStaleConfinement's own per-unit disposition
// (round Z: Z1 deleted the restart; Z3 narrowed the caller's own gate to
// WIDER only, so this is never called for a narrower unit any more — there
// is no narrower branch left to have). REPORT ONLY: never a systemctl
// restart, reload, or stop.
func (r *Reconciler) handleStaleUnit(mod mount.Module, uc unitConfinement) {
	r.cfg.OnError("reconciler:confinement_stale", fmt.Errorf(
		"module %s: unit %s's running capabilities are WIDER than its current manifest declares (bounding running=%#x declared=%#x, ambient extra=%#x) — report only (round Z: no agent-issued restart for this); recover via `systemctl restart %s` or the next recompose",
		mod.ID, uc.Unit, uc.RunningBnd, uc.Declared, uc.RunningAmb&^uc.Declared, uc.Unit))
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
