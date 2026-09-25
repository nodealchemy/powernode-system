package runtime

// Boot state rebase — drop state.json entries for modules the current boot did
// not compose and that nothing shows to be live.
//
// state.json lives on /persist and outlives every boot, but a pivot boot
// composes its root from the boot breadcrumb, never from this file. An entry
// for a module the boot did NOT compose therefore survives indefinitely: it is
// reported in the heartbeat's module digests (the platform's
// running_module_digests, so drift reads it as `extra`), and mount.Reconcile
// proposes its detach every tick — which, on a self-hosted node whose cached
// manifest for it declares services, filterUnsafeDetaches refuses every tick,
// forever. ops-hub carried two such devpin modules this way (offer
// 01a0c60b-c298): not composed, not mounted, no units, not assigned.
//
// Scope is deliberately narrow (review of the first design):
//
//   - ID-level only. An entry is a candidate only when its module ID is ABSENT
//     from the breadcrumb. An ID the boot composed at a DIFFERENT digest is
//     left alone and reported (stageDigestDiverges): dropping it would turn the
//     next diff into a first-attach with no outgoing inventory to prune from,
//     and no restart on a self-hosted node.
//   - Drop-only. The rebase never adds an entry.
//   - Fail closed. A candidate is dropped only when EVERY liveness probe
//     answers "not live": its digest is not mounted at its module mount point,
//     that mount point is not a lower layer of the live `/`, and systemd has no
//     loaded powernode-<id>-* unit. Any probe that cannot answer — and any
//     precondition that does not hold — leaves state.json untouched and
//     unstamped, so the next tick simply asks again.
//   - Once per composition, keyed on the breadcrumb (boot id + compose time),
//     not on the kernel boot id: a soft-reboot recomposes the root under the
//     SAME kernel boot id.
//   - REPORT-ONLY by default. With no switch set, the rebase only emits what it
//     WOULD drop (stageStateWouldRebase) and changes nothing. Dropping requires
//     the enable sentinel; the disable sentinel or powernode.state_rebase=off on
//     the kernel cmdline turns the whole thing off, overriding the enable.
//
// Dropping an entry also drops that module's cached manifest from the
// identity/sudoers/egress render candidates, so every report names what the
// render would lose: users, groups, sudoers grants and egress entries whose
// ONLY source is a dropped module, any user/group whose surviving declaration
// carries a different id, and whether egress enforcement would switch off.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// Switches for the rebase. Vars (not consts) so tests can redirect them. Both
// live on /persist beside the LKG kill switch, readable from a console.
var (
	// StateRebaseEnableSentinel, when present, lets the rebase DROP entries.
	// Without it the rebase is report-only. Creating it is the reviewable,
	// deliberate act that turns the rebase on for a node.
	StateRebaseEnableSentinel = "/persist/var/lib/powernode/state-rebase.enabled"
	// StateRebaseDisableSentinel, when present, turns the rebase off entirely
	// — no report, no drop — and overrides the enable sentinel. So does
	// powernode.state_rebase=off on the kernel cmdline, for when /persist
	// itself is suspect.
	StateRebaseDisableSentinel = "/persist/var/lib/powernode/state-rebase.disabled"

	// currentBootID indirects CurrentBootID so tests can fix the kernel boot
	// id without a real /proc.
	currentBootID = CurrentBootID
)

const (
	stageStateRebased       = "reconciler:state_rebased_dead_modules"
	stageStateWouldRebase   = "reconciler:state_rebase_would_drop"
	stageStateRebaseSkipped = "reconciler:state_rebase_skipped"
	stageDigestDiverges     = "reconciler:state_digest_diverges_from_boot"
)

type stateRebaseMode int

const (
	stateRebaseOff stateRebaseMode = iota
	stateRebaseReportOnly
	stateRebaseEnforce
)

func resolveStateRebaseMode() stateRebaseMode {
	if _, err := os.Stat(StateRebaseDisableSentinel); err == nil {
		return stateRebaseOff
	}
	if cmdlineHasFlag("powernode.state_rebase", "off") {
		return stateRebaseOff
	}
	if _, err := os.Stat(StateRebaseEnableSentinel); err == nil {
		return stateRebaseEnforce
	}
	return stateRebaseReportOnly
}

// stateRebaseKey identifies one boot composition. The kernel boot id alone is
// not enough: a soft-reboot recomposes the root without changing it.
func stateRebaseKey(bc *BootComposedBreadcrumb) string {
	sum := sha256.Sum256([]byte(bc.BootID + "\x00" + bc.ComposedAt.UTC().Format(time.RFC3339Nano)))
	return hex.EncodeToString(sum[:])[:16]
}

// noteStateRebaseOnce emits a rebase signal at most once per process for the
// same stage and text. A skipped or report-only rebase is re-evaluated every
// tick by design; its signal should not be.
func (r *Reconciler) noteStateRebaseOnce(stage string, err error) {
	k := stage + "\x00" + err.Error()
	if r.stateRebaseNoted == nil {
		r.stateRebaseNoted = map[string]bool{}
	}
	if r.stateRebaseNoted[k] {
		return
	}
	r.stateRebaseNoted[k] = true
	r.cfg.OnError(stage, err)
}

func (r *Reconciler) skipStateRebase(format string, args ...any) {
	r.noteStateRebaseOnce(stageStateRebaseSkipped, fmt.Errorf("state rebase not attempted: "+format, args...))
}

// rebaseStateAgainstBoot runs the rebase against current, which RunOnce loaded
// under the state lock. It mutates current only in enforce mode; RunOnce's
// end-of-pass SaveState persists the result. fresh is this tick's freshly
// fetched manifests, used to describe the render impact.
func (r *Reconciler) rebaseStateAgainstBoot(ctx context.Context, current *mount.State, fresh map[string]*manifest.Manifest) {
	mode := resolveStateRebaseMode()
	if mode == stateRebaseOff {
		return
	}
	if r.cfg.DryRun {
		mode = stateRebaseReportOnly
	}

	// A chroot (cloud_init) node recomposes its union from state every tick;
	// there is no boot-fixed root for state to drift from. A probe that cannot
	// tell is not a chroot answer.
	rootMode, err := pivotAwareRootModeChecked()
	if err != nil {
		r.skipStateRebase("cannot determine the root mode (%v)", err)
		return
	}
	if rootMode != lifecycle.RootModeNative {
		return
	}

	bc, err := LoadBreadcrumb(BootBreadcrumbPath)
	if err != nil {
		r.skipStateRebase("no usable boot breadcrumb at %s (%v)", BootBreadcrumbPath, err)
		return
	}
	nowBoot := currentBootID()
	switch {
	case bc.BootID == "":
		r.skipStateRebase("the boot breadcrumb carries no boot id")
		return
	case nowBoot == "":
		r.skipStateRebase("the kernel boot id is unavailable")
		return
	case bc.BootID != nowBoot:
		r.skipStateRebase("the boot breadcrumb is from boot %s, not this boot %s", bc.BootID, nowBoot)
		return
	case bc.Incomplete:
		r.skipStateRebase("the boot breadcrumb is marked incomplete; it is not the full composition")
		return
	}
	key := stateRebaseKey(bc)
	if current.RebasedAgainst == key {
		return
	}

	composed := make(map[string]LKGModule, len(bc.Modules))
	for _, m := range bc.Modules {
		composed[m.ID] = m
	}

	// Entries whose ID the boot composed at another digest: out of scope, but
	// worth saying — the heartbeat reports the state digest, the root runs the
	// breadcrumb's.
	var diverged []string
	for _, m := range current.AttachedModules {
		if bm, ok := composed[m.ID]; ok && bm.HasDataFile && bm.Digest != m.Digest {
			diverged = append(diverged, fmt.Sprintf("%s (state %s, boot %s)", m.ID, m.Digest, bm.Digest))
		}
	}
	if len(diverged) > 0 {
		sort.Strings(diverged)
		r.noteStateRebaseOnce(stageDigestDiverges, fmt.Errorf(
			"%d module(s) in state.json are recorded at a different digest than this boot composed; left unchanged: %s",
			len(diverged), strings.Join(diverged, ", ")))
	}

	var candidates []mount.Module
	for _, m := range current.AttachedModules {
		if _, ok := composed[m.ID]; !ok {
			candidates = append(candidates, m)
		}
	}
	if len(candidates) == 0 {
		if mode == stateRebaseEnforce {
			current.RebasedAgainst = key
		}
		return
	}

	// One strict read of the mount table answers every mount question below.
	table, err := mount.ReadMountTableStrict()
	if err != nil {
		r.skipStateRebase("cannot read the mount table strictly (%v)", err)
		return
	}
	liveRoot := filepath.Join(r.cfg.Layout.Root, "/")
	lowers, err := table.OverlayLowerDirs(liveRoot)
	if err != nil {
		r.skipStateRebase("cannot read the live union at %s (%v)", liveRoot, err)
		return
	}
	if len(lowers) == 0 {
		r.skipStateRebase("the live union at %s lists no lower layers", liveRoot)
		return
	}
	inUnion := make(map[string]bool, len(lowers))
	for _, l := range lowers {
		inUnion[l] = true
	}

	// Cross-check the probes against a known answer before trusting them for
	// an unknown one: every data module the breadcrumb says this boot composed
	// must be mounted AND a lower layer of /. If the tables do not agree with
	// the breadcrumb about the modules it DOES list, they cannot be trusted to
	// prove anything about the ones it does not.
	var mismatch []string
	for _, bm := range bc.Modules {
		if !bm.HasDataFile {
			continue
		}
		if bm.Digest == "" {
			mismatch = append(mismatch, bm.ID+" (no digest)")
			continue
		}
		p := r.cfg.Layout.ModuleMountPath(bm.Digest)
		if !table.IsMounted(p) || !inUnion[filepath.Clean(p)] {
			mismatch = append(mismatch, bm.ID)
		}
	}
	if len(mismatch) > 0 {
		sort.Strings(mismatch)
		r.skipStateRebase("the live mount table disagrees with the boot breadcrumb for %s", strings.Join(mismatch, ", "))
		return
	}

	var dead, kept []mount.Module
	for _, m := range candidates {
		p := filepath.Clean(r.cfg.Layout.ModuleMountPath(m.Digest))
		if table.IsMounted(p) || inUnion[p] {
			kept = append(kept, m)
			continue
		}
		loaded, uerr := r.moduleHasLoadedUnits(ctx, m.ID)
		if uerr != nil {
			r.skipStateRebase("cannot list systemd units for %s (%v)", m.ID, uerr)
			return
		}
		if loaded {
			kept = append(kept, m)
			continue
		}
		dead = append(dead, m)
	}
	if len(dead) == 0 {
		if mode == stateRebaseEnforce {
			current.RebasedAgainst = key
		}
		return
	}

	deadIDs := make(map[string]bool, len(dead))
	names := make([]string, 0, len(dead))
	for _, m := range dead {
		deadIDs[m.ID] = true
		names = append(names, m.ID+"@"+m.Digest)
	}
	sort.Strings(names)
	impact := r.stateRebaseImpact(current, bc, deadIDs, fresh)
	summary := fmt.Sprintf(
		"%d module(s) in state.json are not part of this boot's composition and nothing shows them live (not mounted, not a lower layer of /, no loaded units): %s; %s",
		len(dead), strings.Join(names, ", "), impact.describe())

	if mode != stateRebaseEnforce {
		r.noteStateRebaseOnce(stageStateWouldRebase, fmt.Errorf(
			"REPORT-ONLY, nothing changed (create %s to enable): %s", StateRebaseEnableSentinel, summary))
		return
	}
	if len(impact.unresolved) > 0 {
		r.skipStateRebase("the render impact of dropping %s is unknown (no manifest at the attached digest): %s",
			strings.Join(names, ", "), strings.Join(impact.unresolved, ", "))
		return
	}
	// The render keeps the FIRST declaration of a duplicated user/group, and
	// the order it sees them in comes from map iteration — so while a dead
	// module and a survivor disagree on an id, which one is on disk right now
	// is not knowable, and dropping the dead one could flip it (and the home
	// ownership that follows). Leave that to an operator.
	if len(impact.idConflicts) > 0 {
		r.skipStateRebase("dropping %s would settle a user/group id conflict whose current on-disk winner is not knowable: %s",
			strings.Join(names, ", "), strings.Join(impact.idConflicts, "; "))
		return
	}

	// Keep the pre-rebase file, once per composition, before the first change.
	backup := r.cfg.StatePath + ".pre-rebase-" + key
	if _, serr := os.Stat(backup); errors.Is(serr, os.ErrNotExist) {
		body, rerr := os.ReadFile(r.cfg.StatePath)
		if rerr != nil {
			r.skipStateRebase("cannot read %s to back it up (%v)", r.cfg.StatePath, rerr)
			return
		}
		if werr := fsutil.AtomicWrite(backup, body, 0o644); werr != nil {
			r.skipStateRebase("cannot write the pre-rebase backup %s (%v)", backup, werr)
			return
		}
	} else if serr != nil {
		r.skipStateRebase("cannot stat the pre-rebase backup %s (%v)", backup, serr)
		return
	}

	remaining := current.AttachedModules[:0:0]
	for _, m := range current.AttachedModules {
		if !deadIDs[m.ID] {
			remaining = append(remaining, m)
		}
	}
	current.AttachedModules = remaining
	for id := range deadIDs {
		delete(current.LastAttachedManifestHashes, id)
	}
	if len(current.UnmaterializedModules) > 0 {
		um := current.UnmaterializedModules[:0:0]
		for _, id := range current.UnmaterializedModules {
			if !deadIDs[id] {
				um = append(um, id)
			}
		}
		current.UnmaterializedModules = um
	}
	current.RebasedAgainst = key
	r.cfg.OnError(stageStateRebased, fmt.Errorf("%s (pre-rebase state kept at %s)", summary, backup))
}

// moduleHasLoadedUnits asks systemd, not the unit directory: a unit file on
// disk that systemd never loaded runs nothing, and a loaded unit whose file is
// gone still does.
func (r *Reconciler) moduleHasLoadedUnits(ctx context.Context, moduleID string) (bool, error) {
	out, err := r.cfg.MountRunner.Output(ctx, "systemctl", "list-units", "--all", "--plain", "--no-legend", "--no-pager",
		"powernode-"+moduleID+"-*")
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(out)) != "", nil
}

// stateRebaseRenderImpact is what the identity/sudoers/egress render would
// lose if the dead entries leave the render candidates.
type stateRebaseRenderImpact struct {
	soleUsers, soleGroups, idConflicts, sudoers, soleEgress []string
	egressTurnsOff                                          bool
	// unresolved names dead modules with no manifest at their attached digest:
	// their contribution to today's render cannot be known, so enforce refuses.
	unresolved []string
}

func (i stateRebaseRenderImpact) describe() string {
	list := func(s []string) string {
		if len(s) == 0 {
			return "none"
		}
		return strings.Join(s, ", ")
	}
	d := fmt.Sprintf("render impact: users only they declare [%s]; groups only they declare [%s]; user/group ids that differ from the surviving declaration [%s]; sudoers grants removed [%s]; egress entries only they allow [%s]; egress enforcement turns off: %t",
		list(i.soleUsers), list(i.soleGroups), list(i.idConflicts), list(i.sudoers), list(i.soleEgress), i.egressTurnsOff)
	if len(i.unresolved) > 0 {
		d += fmt.Sprintf("; impact UNKNOWN for [%s] (no manifest at the attached digest)", strings.Join(i.unresolved, ", "))
	}
	return d
}

// stateRebaseImpact compares the dead modules' manifests with every surviving
// render candidate's (the remaining state entries plus the breadcrumb's
// modules), each resolved the way the render resolves it: fresh, else cached at
// the same digest, else the breadcrumb's embedded copy.
func (r *Reconciler) stateRebaseImpact(current *mount.State, bc *BootComposedBreadcrumb, deadIDs map[string]bool, fresh map[string]*manifest.Manifest) stateRebaseRenderImpact {
	resolve := func(id, digest string) *manifest.Manifest {
		if m, ok := fresh[id]; ok && m != nil && (digest == "" || m.Digest == digest) {
			return m
		}
		if m, err := manifest.LoadFromDisk(r.cfg.ManifestRoot, id); err == nil && m != nil && (digest == "" || m.Digest == digest) {
			return m
		}
		return nil
	}

	var imp stateRebaseRenderImpact
	var dead, survivors []*manifest.Manifest
	seen := map[string]bool{}
	for _, m := range current.AttachedModules {
		if deadIDs[m.ID] {
			if mf := resolve(m.ID, m.Digest); mf != nil {
				dead = append(dead, mf)
			} else {
				imp.unresolved = append(imp.unresolved, m.ID)
			}
			continue
		}
		seen[m.ID] = true
		if mf := resolve(m.ID, m.Digest); mf != nil {
			survivors = append(survivors, mf)
		}
	}
	bcManifests, _, _ := loadBreadcrumbManifests()
	for _, bm := range bc.Modules {
		if seen[bm.ID] {
			continue
		}
		if mf := resolve(bm.ID, bm.Digest); mf != nil {
			survivors = append(survivors, mf)
		} else if mf := bcManifests[bm.ID]; mf != nil {
			survivors = append(survivors, mf)
		}
	}

	users := map[string]int{}
	groups := map[string]int{}
	egress := map[string]bool{}
	survivorsEnforce := false
	for _, s := range survivors {
		for _, u := range s.Users {
			if _, ok := users[u.Name]; !ok {
				users[u.Name] = u.UID
			}
		}
		for _, g := range s.Groups {
			if _, ok := groups[g.Name]; !ok {
				groups[g.Name] = g.GID
			}
		}
		p := buildPolicy(s)
		if p.EgressDeclared {
			survivorsEnforce = true
		}
		for _, e := range p.EgressAllow {
			egress[e] = true
		}
	}
	deadEnforce := false
	for _, d := range dead {
		for _, u := range d.Users {
			if uid, ok := users[u.Name]; !ok {
				imp.soleUsers = append(imp.soleUsers, fmt.Sprintf("%s(uid %d, %s)", u.Name, u.UID, d.ID))
			} else if uid != u.UID {
				imp.idConflicts = append(imp.idConflicts, fmt.Sprintf("user %s: %s says %d, surviving %d", u.Name, d.ID, u.UID, uid))
			}
		}
		for _, g := range d.Groups {
			if gid, ok := groups[g.Name]; !ok {
				imp.soleGroups = append(imp.soleGroups, fmt.Sprintf("%s(gid %d, %s)", g.Name, g.GID, d.ID))
			} else if gid != g.GID {
				imp.idConflicts = append(imp.idConflicts, fmt.Sprintf("group %s: %s says %d, surviving %d", g.Name, d.ID, g.GID, gid))
			}
		}
		for _, s := range d.Sudoers {
			imp.sudoers = append(imp.sudoers, "powernode-"+d.Name+"-"+s.ID)
		}
		p := buildPolicy(d)
		if p.EgressDeclared {
			deadEnforce = true
		}
		for _, e := range p.EgressAllow {
			if !egress[e] {
				imp.soleEgress = append(imp.soleEgress, fmt.Sprintf("%s(%s)", e, d.ID))
			}
		}
	}
	imp.egressTurnsOff = deadEnforce && !survivorsEnforce
	for _, s := range [][]string{imp.soleUsers, imp.soleGroups, imp.idConflicts, imp.sudoers, imp.soleEgress, imp.unresolved} {
		sort.Strings(s)
	}
	return imp
}
