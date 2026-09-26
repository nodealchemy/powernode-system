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
// Scope is deliberately narrow (two design reviews):
//
//   - ID-level only. An entry is a candidate only when its module ID is ABSENT
//     from the breadcrumb. An ID the boot composed at a DIFFERENT digest is
//     left alone and reported (stageDigestDiverges): dropping it would turn the
//     next diff into a first-attach with no outgoing inventory to prune from,
//     and no restart on a self-hosted node.
//   - Never an ASSIGNED module. A self-hosted node normally boots FromLKG, so a
//     module hot-attached after the LKG froze is absent from the breadcrumb and
//     can look dead after a reboot — yet dropping it would make the same tick
//     prefetch, mount, hot-copy and start it. Such entries are kept, reported
//     (stageAssignedNotComposed) and never even probed.
//   - Drop-only, and fail closed. A candidate is dropped only when EVERY
//     liveness probe answers "not live": its digest is not mounted at its module
//     mount point, that mount point is not a lower layer of the live `/`, and
//     systemd has no loaded powernode-<id>-* unit. Any probe that cannot answer,
//     and any precondition that does not hold, leaves state.json untouched and
//     unstamped, so a later tick asks again.
//   - Once per composition, keyed on the breadcrumb (boot id + compose time),
//     not on the kernel boot id: a soft-reboot recomposes the root under the
//     SAME kernel boot id.
//   - REPORT-ONLY by default. With no switch set, the rebase only emits what it
//     WOULD drop (stageStateWouldRebase). The enable sentinel lets it drop, but
//     on its own only when the render impact is EMPTY; any other drop needs the
//     sentinel's content to name this composition's key — an approval that
//     cannot outlive the composition it was given for. The disable sentinel or
//     powernode.state_rebase=off on the kernel cmdline turns it off entirely.
//
// Dropping an entry takes its manifest out of the identity/sudoers/egress
// render, so every verdict states the render impact, computed from the
// render's own candidate set (resolveRenderCandidates) with and without the
// dropped modules. An unknown impact, or one that touches a user/group id
// conflict, is never enforced.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/etcidentity"
	"github.com/nodealchemy/powernode-system/agent/internal/etcsudoers"
	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

// Switches for the rebase. Vars (not consts) so tests can redirect them. Both
// live on /persist beside the LKG kill switch, readable from a console.
var (
	// StateRebaseEnableSentinel, when present, lets the rebase DROP entries.
	// Without it the rebase is report-only. A drop whose render impact is not
	// empty additionally needs this file's content to name the reported key
	// (one key per line) — the approval is per composition, never standing.
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
	stageStateRebased        = "reconciler:state_rebased_dead_modules"
	stageStateWouldRebase    = "reconciler:state_rebase_would_drop"
	stageStateRebaseSkipped  = "reconciler:state_rebase_skipped"
	stageDigestDiverges      = "reconciler:state_digest_diverges_from_boot"
	stageAssignedNotComposed = "reconciler:state_assigned_not_composed"
)

type stateRebaseMode int

const (
	stateRebaseOff stateRebaseMode = iota
	stateRebaseReportOnly
	stateRebaseEnforce
)

// resolveStateRebaseMode also returns the enable sentinel's content, which
// carries the per-composition approvals.
func resolveStateRebaseMode() (stateRebaseMode, string) {
	if _, err := os.Stat(StateRebaseDisableSentinel); err == nil {
		return stateRebaseOff, ""
	}
	if cmdlineHasFlag("powernode.state_rebase", "off") {
		return stateRebaseOff, ""
	}
	body, err := os.ReadFile(StateRebaseEnableSentinel)
	if err == nil {
		return stateRebaseEnforce, string(body)
	}
	return stateRebaseReportOnly, ""
}

// stateRebaseApprovalToken is what the enable sentinel must contain to approve
// dropping deadNames (id@digest) under composition key: the key AND a hash of
// the exact dead set reported, so an approval covers precisely what the
// operator read — not a later, different set in the same composition.
func stateRebaseApprovalToken(key string, deadNames []string) string {
	names := append([]string(nil), deadNames...)
	sort.Strings(names)
	sum := sha256.Sum256([]byte(strings.Join(names, "\n")))
	return key + ":" + hex.EncodeToString(sum[:])[:16]
}

func approvalNames(approval, token string) bool {
	for _, line := range strings.Split(approval, "\n") {
		if strings.TrimSpace(line) == token {
			return true
		}
	}
	return false
}

// stateRebaseInputs is what RunOnce already knows about this tick.
type stateRebaseInputs struct {
	fresh       map[string]*manifest.Manifest // this tick's fresh manifests
	fetchFailed map[string]bool               // assigned modules whose fetch failed
	assigned    map[string]bool               // every assigned module id
}

// breadcrumbHeader is the part of the breadcrumb the per-tick short-circuit
// needs; decoding it skips the embedded manifests.
type breadcrumbHeader struct {
	BootID     string    `json:"boot_id"`
	ComposedAt time.Time `json:"composed_at"`
	Incomplete bool      `json:"incomplete"`
}

func loadBreadcrumbHeader(path string) (*breadcrumbHeader, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var h breadcrumbHeader
	if err := json.Unmarshal(body, &h); err != nil {
		return nil, fmt.Errorf("decode breadcrumb %s: %w", path, err)
	}
	return &h, nil
}

// stateRebaseKey identifies one boot composition. The kernel boot id alone is
// not enough: a soft-reboot recomposes the root without changing it.
func stateRebaseKey(bc *BootComposedBreadcrumb) string {
	return stateRebaseKeyOf(bc.BootID, bc.ComposedAt)
}

func stateRebaseKeyOf(bootID string, composedAt time.Time) string {
	sum := sha256.Sum256([]byte(bootID + "\x00" + composedAt.UTC().Format(time.RFC3339Nano)))
	return hex.EncodeToString(sum[:])[:16]
}

// stateRebaseFingerprint is everything besides the composition key that could
// change a verdict: the mode and approvals, the state entries and the assigned
// set. A report-only (or awaiting-approval) verdict is memoised against it, so
// an unchanged node is not re-probed every tick.
func stateRebaseFingerprint(mode stateRebaseMode, approval string, current *mount.State, assigned map[string]bool) string {
	parts := make([]string, 0, len(current.AttachedModules)+len(assigned)+2)
	parts = append(parts, fmt.Sprintf("mode=%d", mode), "approval="+approval)
	for _, m := range current.AttachedModules {
		parts = append(parts, "s:"+m.ID+"@"+m.Digest)
	}
	for id := range assigned {
		parts = append(parts, "a:"+id)
	}
	sort.Strings(parts[2:])
	sum := sha256.Sum256([]byte(strings.Join(parts, "\n")))
	return hex.EncodeToString(sum[:])
}

// stateRebaseEval collects the conditions one evaluation raised. A condition
// is signalled when it is raised and was not raised by the previous
// evaluation, so a standing condition is reported once and one that clears
// and returns is reported again. Conditions are keyed by a stable id, never
// by their text.
type stateRebaseEval struct {
	r      *Reconciler
	raised map[string]bool
}

func (ev *stateRebaseEval) note(stage, cond string, err error) {
	ev.raised[cond] = true
	if ev.r.stateRebaseActive[cond] {
		return
	}
	ev.r.cfg.OnError(stage, err)
}

func (ev *stateRebaseEval) skip(cond, format string, args ...any) {
	ev.note(stageStateRebaseSkipped, "skip:"+cond, fmt.Errorf("state rebase not attempted: "+format, args...))
}

// rebaseStateAgainstBoot runs the rebase against current, which RunOnce loaded
// under the state lock. It mutates current only when it enforces a drop;
// RunOnce's end-of-pass SaveState persists the result.
func (r *Reconciler) rebaseStateAgainstBoot(ctx context.Context, current *mount.State, in stateRebaseInputs) {
	mode, approval := resolveStateRebaseMode()
	if mode == stateRebaseOff {
		r.stateRebaseActive, r.stateRebaseMemo = nil, ""
		return
	}
	if r.cfg.DryRun {
		mode = stateRebaseReportOnly
	}
	ev := &stateRebaseEval{r: r, raised: map[string]bool{}}
	memoHit := false
	defer func() {
		if !memoHit {
			r.stateRebaseActive = ev.raised
		}
	}()

	// A chroot (cloud_init) node recomposes its union from state every tick;
	// there is no boot-fixed root for state to drift from. A probe that cannot
	// tell is not a chroot answer.
	rootMode, err := pivotAwareRootModeChecked()
	if err != nil {
		ev.skip("root-mode", "cannot determine the root mode (%v)", err)
		return
	}
	if rootMode != lifecycle.RootModeNative {
		return
	}

	hdr, err := loadBreadcrumbHeader(BootBreadcrumbPath)
	if err != nil {
		ev.skip("breadcrumb", "no usable boot breadcrumb at %s (%v)", BootBreadcrumbPath, err)
		return
	}
	nowBoot := currentBootID()
	switch {
	case hdr.BootID == "":
		ev.skip("breadcrumb-boot-id", "the boot breadcrumb carries no boot id")
		return
	case nowBoot == "":
		ev.skip("kernel-boot-id", "the kernel boot id is unavailable")
		return
	case hdr.BootID != nowBoot:
		ev.skip("breadcrumb-other-boot", "the boot breadcrumb is from boot %s, not this boot %s", hdr.BootID, nowBoot)
		return
	case hdr.Incomplete:
		ev.skip("breadcrumb-incomplete", "the boot breadcrumb is marked incomplete; it is not the full composition")
		return
	}
	key := stateRebaseKeyOf(hdr.BootID, hdr.ComposedAt)
	if current.RebasedAgainst == key {
		return
	}
	memo := key + "/" + stateRebaseFingerprint(mode, approval, current, in.assigned)
	if r.stateRebaseMemo == memo {
		memoHit = true
		return
	}

	bc, err := LoadBreadcrumb(BootBreadcrumbPath)
	if err != nil {
		ev.skip("breadcrumb", "no usable boot breadcrumb at %s (%v)", BootBreadcrumbPath, err)
		return
	}
	if stateRebaseKey(bc) != key || bc.Incomplete {
		ev.skip("breadcrumb-changed", "the boot breadcrumb changed while it was being read")
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
		ev.note(stageDigestDiverges, "diverges:"+key+":"+strings.Join(diverged, ","), fmt.Errorf(
			"%d module(s) in state.json are recorded at a different digest than this boot composed; left unchanged: %s",
			len(diverged), strings.Join(diverged, ", ")))
	}

	var candidates []mount.Module
	var assignedNotComposed []string
	for _, m := range current.AttachedModules {
		if _, ok := composed[m.ID]; ok {
			continue
		}
		if in.assigned[m.ID] {
			assignedNotComposed = append(assignedNotComposed, m.ID+"@"+m.Digest)
			continue
		}
		candidates = append(candidates, m)
	}
	if len(assignedNotComposed) > 0 {
		sort.Strings(assignedNotComposed)
		ev.note(stageAssignedNotComposed, "assigned-not-composed:"+key+":"+strings.Join(assignedNotComposed, ","), fmt.Errorf(
			"%d ASSIGNED module(s) in state.json are not part of this boot's composition; kept, never probed or dropped — dropping one would make this tick re-attach it (prefetch, mount, hot-copy, start its services): %s",
			len(assignedNotComposed), strings.Join(assignedNotComposed, ", ")))
	}
	if len(candidates) == 0 {
		r.settleStateRebase(mode, current, key, memo)
		return
	}

	// One strict read of the mount table answers every mount question below.
	table, err := mount.ReadMountTableStrict()
	if err != nil {
		ev.skip("mount-table", "cannot read the mount table strictly (%v)", err)
		return
	}
	liveRoot := filepath.Join(r.cfg.Layout.Root, "/")
	lowers, err := table.OverlayLowerDirs(liveRoot)
	if err != nil {
		ev.skip("live-union", "cannot read the live union at %s (%v)", liveRoot, err)
		return
	}
	if len(lowers) == 0 {
		ev.skip("live-union-empty", "the live union at %s lists no lower layers", liveRoot)
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
		ev.skip("cross-check", "the live mount table disagrees with the boot breadcrumb for %s", strings.Join(mismatch, ", "))
		return
	}

	var dead []mount.Module
	for _, m := range candidates {
		p := filepath.Clean(r.cfg.Layout.ModuleMountPath(m.Digest))
		if table.IsMounted(p) || inUnion[p] {
			continue
		}
		loaded, uerr := r.moduleHasLoadedUnits(ctx, m.ID)
		if uerr != nil {
			ev.skip("units:"+m.ID, "cannot list systemd units for %s (%v)", m.ID, uerr)
			return
		}
		if loaded {
			continue
		}
		dead = append(dead, m)
	}
	if len(dead) == 0 {
		r.settleStateRebase(mode, current, key, memo)
		return
	}

	deadIDs := make(map[string]bool, len(dead))
	names := make([]string, 0, len(dead))
	for _, m := range dead {
		deadIDs[m.ID] = true
		names = append(names, m.ID+"@"+m.Digest)
	}
	sort.Strings(names)
	impact := r.stateRebaseImpact(current, bc, deadIDs, in)
	summary := fmt.Sprintf(
		"%d module(s) in state.json are not part of this boot's composition and nothing shows them live (not mounted, not a lower layer of /, no loaded units): %s; %s",
		len(dead), strings.Join(names, ", "), impact.describe())
	token := stateRebaseApprovalToken(key, names)
	howToApply := fmt.Sprintf("create %s to apply", StateRebaseEnableSentinel)
	if !impact.empty() {
		howToApply = fmt.Sprintf("the render impact is not empty, so applying needs %s to contain the approval token %s", StateRebaseEnableSentinel, token)
	}
	wouldCond := "would-drop:" + key + ":" + strings.Join(names, ",")

	if mode != stateRebaseEnforce {
		ev.note(stageStateWouldRebase, wouldCond, fmt.Errorf("REPORT-ONLY, nothing changed (%s): %s", howToApply, summary))
		r.stateRebaseMemo = memo
		return
	}
	if len(impact.unresolved) > 0 {
		ev.skip("impact-unknown", "the render impact of dropping %s is unknown; unresolved render candidates: %s",
			strings.Join(names, ", "), strings.Join(impact.unresolved, ", "))
		return
	}
	// The render keeps the FIRST declaration of a duplicated user/group, and
	// the order it sees them in comes from map iteration (offer 01a0da22) — so
	// while a dead module and a survivor disagree on an id, which one is on
	// disk right now is not knowable, and dropping the dead one could flip it
	// (and the home ownership that follows). Leave that to an operator.
	if len(impact.idConflicts) > 0 {
		ev.skip("impact-conflict", "dropping %s would settle a user/group id conflict whose current on-disk winner is not knowable: %s",
			strings.Join(names, ", "), strings.Join(impact.idConflicts, "; "))
		return
	}
	if !impact.empty() && !approvalNames(approval, token) {
		ev.note(stageStateWouldRebase, wouldCond, fmt.Errorf("AWAITING APPROVAL, nothing changed (%s): %s", howToApply, summary))
		r.stateRebaseMemo = memo
		return
	}

	// Keep the pre-rebase file, once per composition, before the first change.
	backup := r.cfg.StatePath + ".pre-rebase-" + key
	if _, serr := os.Stat(backup); errors.Is(serr, os.ErrNotExist) {
		body, rerr := os.ReadFile(r.cfg.StatePath)
		if rerr != nil {
			ev.skip("backup", "cannot read %s to back it up (%v)", r.cfg.StatePath, rerr)
			return
		}
		if werr := fsutil.AtomicWrite(backup, body, 0o644); werr != nil {
			ev.skip("backup", "cannot write the pre-rebase backup %s (%v)", backup, werr)
			return
		}
	} else if serr != nil {
		ev.skip("backup", "cannot stat the pre-rebase backup %s (%v)", backup, serr)
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
	r.stateRebaseMemo = ""
	r.cfg.OnError(stageStateRebased, fmt.Errorf("%s (pre-rebase state kept at %s)", summary, backup))
}

// settleStateRebase records a verdict with nothing to drop: an enforcing
// rebase stamps the composition done, a report-only one memoises it.
func (r *Reconciler) settleStateRebase(mode stateRebaseMode, current *mount.State, key, memo string) {
	if mode == stateRebaseEnforce {
		current.RebasedAgainst = key
		r.stateRebaseMemo = ""
		return
	}
	r.stateRebaseMemo = memo
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

// stateRebaseRenderImpact is how the identity/sudoers/egress render would
// change if the dead entries leave the render candidates.
type stateRebaseRenderImpact struct {
	soleUsers, soleGroups, changed, idConflicts, sudoers, soleEgress []string
	egressTurnsOff                                                   bool
	// unresolved names render candidates with no resolvable manifest, before
	// or after the drop: the impact cannot be known.
	unresolved []string
}

func (i stateRebaseRenderImpact) empty() bool {
	return len(i.soleUsers)+len(i.soleGroups)+len(i.changed)+len(i.idConflicts)+len(i.sudoers)+len(i.soleEgress)+len(i.unresolved) == 0 &&
		!i.egressTurnsOff
}

func (i stateRebaseRenderImpact) describe() string {
	list := func(s []string) string {
		if len(s) == 0 {
			return "none"
		}
		return strings.Join(s, ", ")
	}
	d := fmt.Sprintf("render impact: users only they declare [%s]; groups only they declare [%s]; user/group entries that would change [%s]; user/group ids that differ from the surviving declaration [%s]; sudoers grants removed [%s]; egress entries only they allow [%s]; egress enforcement turns off: %t",
		list(i.soleUsers), list(i.soleGroups), list(i.changed), list(i.idConflicts), list(i.sudoers), list(i.soleEgress), i.egressTurnsOff)
	if len(i.unresolved) > 0 {
		d += fmt.Sprintf("; impact UNKNOWN, unresolved render candidates [%s]", strings.Join(i.unresolved, ", "))
	}
	return d
}

// stateRebaseImpact builds the render's own candidate set twice — with the
// state as it is, and with the dead entries gone — and diffs what the render
// would produce from each.
func (r *Reconciler) stateRebaseImpact(current *mount.State, bc *BootComposedBreadcrumb, deadIDs map[string]bool, in stateRebaseInputs) stateRebaseRenderImpact {
	bcManifests, bcIDs, bcDataIDs := breadcrumbManifestSets(bc)
	survivors := make([]mount.Module, 0, len(current.AttachedModules))
	for _, m := range current.AttachedModules {
		if !deadIDs[m.ID] {
			survivors = append(survivors, m)
		}
	}
	before := r.resolveRenderCandidates(in.fresh, current.AttachedModules, in.fetchFailed, bcManifests, bcIDs, bcDataIDs)
	after := r.resolveRenderCandidates(in.fresh, survivors, in.fetchFailed, bcManifests, bcIDs, bcDataIDs)

	var imp stateRebaseRenderImpact
	unresolved := map[string]bool{}
	for _, id := range append(append([]string{}, before.unresolvedReal...), after.unresolvedReal...) {
		unresolved[id] = true
	}
	for id := range unresolved {
		imp.unresolved = append(imp.unresolved, id)
	}

	sorted := func(m map[string]*manifest.Manifest) []*manifest.Manifest {
		ids := make([]string, 0, len(m))
		for id := range m {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		out := make([]*manifest.Manifest, 0, len(ids))
		for _, id := range ids {
			out = append(out, m[id])
		}
		return out
	}
	beforeSet, afterSet := sorted(before.merged), sorted(after.merged)
	var dead []*manifest.Manifest
	for _, m := range beforeSet {
		if deadIDs[m.ID] {
			dead = append(dead, m)
		}
	}

	bIdent, _ := etcidentity.Collect(beforeSet)
	aIdent, _ := etcidentity.Collect(afterSet)
	aUsers := map[string]etcidentity.User{}
	for _, u := range aIdent.Users {
		aUsers[u.Name] = u
	}
	aGroups := map[string]etcidentity.Group{}
	for _, g := range aIdent.Groups {
		aGroups[g.Name] = g
	}
	conflicted := map[string]bool{}
	for _, d := range dead {
		for _, u := range d.Users {
			if au, ok := aUsers[u.Name]; ok && au.UID != u.UID {
				imp.idConflicts = append(imp.idConflicts, fmt.Sprintf("user %s: %s says %d, surviving %d", u.Name, d.ID, u.UID, au.UID))
				conflicted["user:"+u.Name] = true
			}
		}
		for _, g := range d.Groups {
			if ag, ok := aGroups[g.Name]; ok && ag.GID != g.GID {
				imp.idConflicts = append(imp.idConflicts, fmt.Sprintf("group %s: %s says %d, surviving %d", g.Name, d.ID, g.GID, ag.GID))
				conflicted["group:"+g.Name] = true
			}
		}
	}
	// The render's real order is map order (offer 01a0da22), so which of two
	// declarations of the same name is on disk is not knowable, and the
	// before/after diff below — taken over ID-sorted sets — would call a dead
	// module's variant "no change" whenever its ID happens to sort after the
	// survivor's. Compare the dead module's OWN line with the surviving one:
	// any difference is a change the drop could make.
	for _, d := range dead {
		for _, u := range d.Users {
			au, ok := aUsers[u.Name]
			if !ok || conflicted["user:"+u.Name] {
				continue
			}
			own := etcidentity.User{Name: u.Name, UID: u.UID, PrimaryGID: u.PrimaryGID, PrimaryGroup: u.PrimaryGroup,
				Shell: u.Shell, Home: u.Home, Gecos: u.Gecos, SupplementaryGroups: u.SupplementaryGroups}
			if string(etcidentity.RenderPasswd(&etcidentity.Set{Users: []etcidentity.User{own}})) !=
				string(etcidentity.RenderPasswd(&etcidentity.Set{Users: []etcidentity.User{au}})) ||
				strings.Join(own.SupplementaryGroups, ",") != strings.Join(au.SupplementaryGroups, ",") {
				imp.changed = append(imp.changed, fmt.Sprintf("user %s (%s declares a different entry)", u.Name, d.ID))
			}
		}
		for _, g := range d.Groups {
			ag, ok := aGroups[g.Name]
			if !ok || conflicted["group:"+g.Name] {
				continue
			}
			// Members merge across declarations, so only members the survivors
			// would NOT keep are a change.
			kept := map[string]bool{}
			for _, m := range ag.Members {
				kept[m] = true
			}
			for _, m := range g.Members {
				if !kept[m] {
					imp.changed = append(imp.changed, fmt.Sprintf("group %s loses member %s (%s)", g.Name, m, d.ID))
				}
			}
		}
	}
	declaredBy := func(kind, name string) string {
		var ids []string
		for _, d := range dead {
			if kind == "user" {
				for _, u := range d.Users {
					if u.Name == name {
						ids = append(ids, d.ID)
					}
				}
			} else {
				for _, g := range d.Groups {
					if g.Name == name {
						ids = append(ids, d.ID)
					}
				}
			}
		}
		return strings.Join(ids, "+")
	}
	for _, u := range bIdent.Users {
		au, ok := aUsers[u.Name]
		switch {
		case !ok:
			imp.soleUsers = append(imp.soleUsers, fmt.Sprintf("%s(uid %d, %s)", u.Name, u.UID, declaredBy("user", u.Name)))
		case !conflicted["user:"+u.Name] && string(etcidentity.RenderPasswd(&etcidentity.Set{Users: []etcidentity.User{u}})) !=
			string(etcidentity.RenderPasswd(&etcidentity.Set{Users: []etcidentity.User{au}})):
			imp.changed = append(imp.changed, "user "+u.Name)
		}
	}
	for _, g := range bIdent.Groups {
		ag, ok := aGroups[g.Name]
		switch {
		case !ok:
			imp.soleGroups = append(imp.soleGroups, fmt.Sprintf("%s(gid %d, %s)", g.Name, g.GID, declaredBy("group", g.Name)))
		case !conflicted["group:"+g.Name] && string(etcidentity.RenderGroup(&etcidentity.Set{Groups: []etcidentity.Group{g}})) !=
			string(etcidentity.RenderGroup(&etcidentity.Set{Groups: []etcidentity.Group{ag}})):
			imp.changed = append(imp.changed, "group "+g.Name)
		}
	}

	aSudo := map[string]bool{}
	for _, g := range etcsudoers.CollectFromManifests(afterSet) {
		aSudo[g.Filename()] = true
	}
	for _, g := range etcsudoers.CollectFromManifests(beforeSet) {
		if !aSudo[g.Filename()] {
			imp.sudoers = append(imp.sudoers, g.Filename())
		}
	}

	policies := func(ms []*manifest.Manifest) []*security.Policy {
		out := make([]*security.Policy, 0, len(ms))
		for _, m := range ms {
			out = append(out, buildPolicy(m))
		}
		return out
	}
	bAllow, bEnforced := security.UnionEgressPolicy(policies(beforeSet))
	aAllow, aEnforced := security.UnionEgressPolicy(policies(afterSet))
	kept := map[string]bool{}
	for _, e := range aAllow {
		kept[e] = true
	}
	for _, e := range bAllow {
		if kept[e] {
			continue
		}
		var from []string
		for _, d := range dead {
			for _, de := range buildPolicy(d).EgressAllow {
				if de == e {
					from = append(from, d.ID)
				}
			}
		}
		imp.soleEgress = append(imp.soleEgress, fmt.Sprintf("%s(%s)", e, strings.Join(from, "+")))
	}
	imp.egressTurnsOff = bEnforced && !aEnforced

	uniq := func(s []string) []string {
		sort.Strings(s)
		out := s[:0]
		for i, v := range s {
			if i == 0 || v != s[i-1] {
				out = append(out, v)
			}
		}
		return out
	}
	imp.soleUsers, imp.soleGroups, imp.changed = uniq(imp.soleUsers), uniq(imp.soleGroups), uniq(imp.changed)
	imp.idConflicts, imp.sudoers, imp.soleEgress, imp.unresolved = uniq(imp.idConflicts), uniq(imp.sudoers), uniq(imp.soleEgress), uniq(imp.unresolved)
	return imp
}
