package runtime

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/etcidentity"
	"github.com/nodealchemy/powernode-system/agent/internal/etcsudoers"
	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/oci"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// pivotAwareRootMode indirects lifecycle.PivotAwareRootMode so tests in
// this package can force the native-root (pivot node) gate without
// touching lifecycle's own root probe, which is unexported and keyed off
// the live process's actual "/" filesystem type — not fakeable from
// outside that package. Mirrors the same var-indirection pattern
// lifecycle/service.go itself uses internally (rootFSType).
var pivotAwareRootMode = lifecycle.PivotAwareRootMode

// PullerAPI is the subset of *oci.Puller the reconciler depends on.
// Defined as an interface so tests can stub without standing up an
// httptest server for the blob download path.
type PullerAPI interface {
	Pull(ref *oci.ModuleArtifactRef) (cfsPath, bundlePath string, err error)
}

// ReconcilerConfig wires the reconciler's dependencies. Each field is
// independently injectable so tests can stub piecewise.
type ReconcilerConfig struct {
	// ModulesClient fetches the assigned-modules list from the platform.
	// Typically *transport.Client or *transport.SwappableClient.
	ModulesClient ModulesClient
	// ManifestClient fetches per-module manifests + caches them on disk.
	// Same client as ModulesClient in production; the manifest loader
	// only needs GetJSON.
	ManifestClient manifest.Client
	// ManifestRoot is the cache root for on-disk manifest JSON files.
	// Defaults to manifest.DefaultRoot when empty.
	ManifestRoot string
	// Puller pulls module artifacts (erofs blob + cosign bundle).
	Puller PullerAPI
	// Verifier verifies cosign signatures against the bundle. May be
	// verify.AlwaysOK in dev/test.
	Verifier verify.Verifier
	// Fsverity verifies fs-verity Merkle-tree root hash matches expected.
	Fsverity *verify.FsVerifier
	// MountRunner is the os/exec abstraction used by mount/security/systemd.
	MountRunner mount.Runner
	// Layout describes mount points (modules cache, sysroot, etc.).
	Layout mount.Layout
	// StatePath is where mount.LoadState/SaveState reads + writes.
	// Defaults to mount.StatePath when empty.
	StatePath string
	// Interval is the gap between full reconcile cycles in Run(ctx).
	// Default 60s, jittered ±10%.
	Interval time.Duration
	// ManifestTTL bounds how long a cached manifest is trusted before the
	// reconcile loop refetches it from the platform. Zero would mean "cache
	// forever", which silently pins the agent to a stale module digest — a
	// rebuilt+republished module's new digest is never seen, so it is never
	// re-pulled (every update otherwise needs a manual cache-clear). Defaults
	// to 90s: slightly longer than the 60s reconcile interval so a steady
	// fleet refetches roughly every other tick rather than every tick, while
	// still surfacing a republished module within ~2 cycles.
	ManifestTTL time.Duration
	// DryRun, when true, computes the diff + plan but skips all
	// mutations (no pull, no mount, no systemd action).
	DryRun bool
	// OnError surfaces non-fatal reconcile-stage errors. Persistent
	// errors stay in the reconciler's lastErrors field for heartbeat
	// reporting.
	OnError func(stage string, err error)
	// PlatformURL is the base URL the agent's runtime client speaks to
	// (heartbeat, task-lease, federation, module pulls). The reconciler
	// passes the host portion of this into Policy.ProtectedHosts so the
	// egress chain never drops the agent's own control-plane traffic
	// even when a strict module attaches with an empty EgressAllow list.
	PlatformURL string
	// ScratchMinFreeBytes is the free-space floor the hot-reconcile
	// budget guard keeps on the scratch tmpfs backing the live root's
	// overlay upperdir (see SyncOptions.MinFreeBytes). 0 means
	// DefaultScratchMinFreeBytes.
	ScratchMinFreeBytes uint64
	// BreadcrumbSink, when set, receives ComposeForPivot's boot-composed
	// breadcrumb INSTEAD of it being written to BootBreadcrumbPath. Set
	// only by the soft-recompose prepare path — see the write site in
	// compose.go for why the on-disk write must wait for execute time.
	BreadcrumbSink func(*BootComposedBreadcrumb)
}

// DefaultScratchMinFreeBytes is the default budget-guard floor: a live
// materialization never takes the scratch tmpfs below this much free.
// 64 MiB of the (default 512 MiB) scratch pool: enough headroom for the
// overlay's own copy-up traffic — identity renders, unit writes, service
// runtime writes — to keep landing while a large module sync is refused.
const DefaultScratchMinFreeBytes uint64 = 64 << 20

// Reconciler is the long-lived module-state reconcile loop. Pulls the
// platform's assigned-modules list, diffs vs on-disk state.json,
// pulls + verifies + mounts new modules, unmounts removed ones,
// applies security policy, runs init_start units, recomposes the
// overlay union, persists state.
type Reconciler struct {
	cfg ReconcilerConfig

	mu              sync.Mutex
	lastReconcileAt time.Time
	lastError       error
	// composeFailed records whether the LAST pass that got as far as composing
	// observed a module attach or union-mount failure. Distinct from lastError,
	// which deliberately does NOT cover these — see ComposedOK.
	//
	// ATOMIC, not guarded by mu, because the boot-confirm gate reads it on every
	// probe and mu is held across the ENTIRE RunOnce body — network fetches,
	// ~80MB blob pulls, systemctl, mount. Reading it under mu would park the
	// confirm loop for minutes: the same stall the systemctl probe timeout
	// exists to prevent, and worse, since it is checked BEFORE that timeout
	// applies and would suppress the stuck-gate warning that is only evaluated
	// after a probe returns. sync.Mutex.Lock is also not context-aware, so a
	// parked probe would hold up agent shutdown at wg.Wait().
	composeFailed atomic.Bool

	// Latched result of the self-host probe (see selfhost.go). Guarded
	// separately from mu because selfHosted() is called from inside a
	// RunOnce that already holds mu.
	selfHostMu      sync.Mutex
	selfHostLatched bool

	// IMP-f1c1e6d61104 — per-module convergence failures observed by the LAST
	// pass, reset at the top of RunOnce. Read by the apply_config/sync task
	// handler so a pass that did not converge the desired set FAILS the task
	// instead of completing.
	//
	// Why this exists: every per-module failure below reports through
	// cfg.OnError, which in service mode is a bare stderr printf — the platform
	// never sees it. RunOnce returns an error only for whole-pass failures
	// (fetch-assigned-modules, state lock, load state), so a pass that declined
	// to materialize a module still returned nil and the task COMPLETED. The
	// server's ConfigDriftSensor suppresses `system.config_drift` for a node on
	// a completed apply_config, so a vacuous completion silenced real drift.
	//
	// Deliberately NOT folded into composeFailed: that flag is the boot-confirm
	// bless gate (see ComposedOK) and covers attach/union-mount only. Widening
	// it would make a scratch-budget abort block an image promotion, which is a
	// different decision that nobody has taken.
	//
	// Its own mutex rather than mu: mu is held across the ENTIRE RunOnce body,
	// and every writer below runs inside that body, so reusing mu would
	// self-deadlock (sync.Mutex is not reentrant).
	convergeMu       sync.Mutex
	convergeFailures []string

	// privilegedAllow is the operator-approved privileged-module allowlist for
	// THIS pass, copied from the fetched AssignmentMeta at the top of RunOnce.
	// Read by attachModule (and ComposeForPivot uses its own live meta). Set
	// and read only within a single RunOnce, which holds mu across its whole
	// body, so no separate guard is needed. See privilegedApproved.
	privilegedAllow []string
}

// privilegedApproved reports whether a module that REQUESTS
// security.privileged=true has been GRANTED it by the operator-controlled
// allowlist (AssignmentMeta.PrivilegedModuleIDs). The manifest can only ask;
// this list — delivered by the control plane from an admin-gated setting,
// never from the module manifest — decides. Empty allowlist = deny.
//
// Matching is on modID ONLY — the server-assigned NodeModule UUIDv7. The
// server resolves any operator-supplied module NAMES to these ids before
// sending them (NodeApi::ModulesController#privileged_module_ids), so the
// agent never keys the gate on a mutable, author-influenced name (review
// finding F1): two modules sharing a name can never both inherit an approval.
//
// This is the crux of the gate against IMP-01a02f70-20b1: it can NEVER be
// satisfied by module-controlled input, because the only value it consults —
// the immutable assignment id — is compared against a list the module does not
// author. A compromised module cannot add itself.
func privilegedApproved(modID string, allow []string) bool {
	if modID == "" {
		return false
	}
	for _, a := range allow {
		if strings.TrimSpace(a) == modID {
			return true
		}
	}
	return false
}

// noteUnconverged records a convergence failure AND reports it through the
// existing OnError sink, so adding the task-failure channel does not remove the
// operator-facing log line any of these sites already produced.
//
// Recorded as a formatted string rather than a struct on purpose: the consumer
// is tasks.ConvergenceReporter, and that interface lives in the tasks package
// to avoid an import cycle — so it cannot name a type defined here.
func (r *Reconciler) noteUnconverged(stage, moduleID string, err error) {
	entry := stage
	if moduleID != "" {
		entry += " [" + moduleID + "]"
	}
	entry += ": " + err.Error()

	r.convergeMu.Lock()
	r.convergeFailures = append(r.convergeFailures, entry)
	r.convergeMu.Unlock()
	r.cfg.OnError(stage, err)
}

// resetConvergence clears the previous pass's failures. Called at the top of
// RunOnce so the list always describes the pass the caller just ran, never an
// older one.
func (r *Reconciler) resetConvergence() {
	r.convergeMu.Lock()
	r.convergeFailures = nil
	r.convergeMu.Unlock()
}

// ConvergenceFailures returns the failures observed by the last completed pass.
// Satisfies tasks.ConvergenceReporter.
func (r *Reconciler) ConvergenceFailures() []string {
	r.convergeMu.Lock()
	defer r.convergeMu.Unlock()
	out := make([]string, len(r.convergeFailures))
	copy(out, r.convergeFailures)
	return out
}

// NewReconciler validates required fields and returns a Reconciler.
// Returns nil + error when a required dependency is absent.
func NewReconciler(cfg ReconcilerConfig) (*Reconciler, error) {
	if cfg.ModulesClient == nil {
		return nil, errors.New("NewReconciler: ModulesClient required")
	}
	if cfg.ManifestClient == nil {
		return nil, errors.New("NewReconciler: ManifestClient required")
	}
	if cfg.Puller == nil {
		return nil, errors.New("NewReconciler: Puller required")
	}
	if cfg.Verifier == nil {
		return nil, errors.New("NewReconciler: Verifier required (use verify.AlwaysOK in dev only)")
	}
	if cfg.MountRunner == nil {
		return nil, errors.New("NewReconciler: MountRunner required")
	}
	if cfg.ManifestRoot == "" {
		cfg.ManifestRoot = manifest.DefaultRoot
	}
	if cfg.StatePath == "" {
		cfg.StatePath = mount.StatePath
	}
	if cfg.Interval == 0 {
		cfg.Interval = 60 * time.Second
	}
	if cfg.ManifestTTL == 0 {
		cfg.ManifestTTL = 90 * time.Second
	}
	if cfg.OnError == nil {
		cfg.OnError = func(string, error) {}
	}
	return &Reconciler{cfg: cfg}, nil
}

// Run blocks until ctx is canceled. Each tick: jitter the interval
// (±10%), call RunOnce, surface the error if any. The loop never
// crashes — failures stay in lastError and are visible via Status.
func (r *Reconciler) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		if err := r.RunOnce(ctx); err != nil {
			r.cfg.OnError("reconciler", err)
		}

		jitter := time.Duration(rand.Int63n(int64(r.cfg.Interval) / 5))
		sleep := r.cfg.Interval + jitter - r.cfg.Interval/10
		select {
		case <-ctx.Done():
			return
		case <-time.After(sleep):
		}
	}
}

// RunOnce runs one reconcile cycle synchronously. Used by both Run()
// and the Phase 2 `update`/`sync` CLI commands.
//
// Sequence (per the implementation plan):
//  1. Fetch desired modules from platform
//  2. For each module with a data file: fetch manifest
//  3. Take state lock; load current state
//  4. Compute diff (mount.Reconcile)
//  5. Apply detaches first (reverse priority order)
//  6. Apply attaches (priority order): pull → verify → mount → policy → start
//  7. Recompose union mount
//  8. Persist state
//  9. Release lock
func (r *Reconciler) RunOnce(ctx context.Context) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	// IMP-f1c1e6d61104 — this pass's convergence verdict starts empty.
	r.resetConvergence()

	// E8: realize the durable-storage binding before module attaches,
	// so any module unit start (e.g. postgres) finds its data
	// directory already on the persistent mount. Best-effort: failure
	// here surfaces via OnError but doesn't block the module-reconcile
	// pass — modules without a volume binding still need to come up.
	if binding, err := FetchStorageVolume(ctx, r.cfg.ModulesClient); err != nil {
		r.cfg.OnError("reconciler:fetch_storage_volume", err)
	} else if !r.cfg.DryRun {
		if err := mount.ReconcileStorageVolume(ctx, r.cfg.MountRunner, binding); err != nil {
			r.cfg.OnError("reconciler:storage_volume", err)
		}
	}

	desiredModules, assignmentMeta, err := FetchAssignedModules(ctx, r.cfg.ModulesClient)
	if err != nil {
		r.lastError = fmt.Errorf("fetch assigned modules: %w", err)
		return r.lastError
	}
	// Operator-approved privileged-module allowlist for this pass. buildPolicy
	// parses a module's privileged REQUEST; attachModule consults this to
	// decide whether to honour it (IMP-01a02f70-20b1).
	r.privilegedAllow = assignmentMeta.PrivilegedModuleIDs

	// Build desired ModuleStack by fetching manifests for modules with data files.
	desired := make(mount.ModuleStack, 0, len(desiredModules))
	manifests := make(map[string]*manifest.Manifest, len(desiredModules))
	for _, mod := range desiredModules {
		if !mod.HasDataFile {
			continue // config-variety + skill modules have no blob to mount
		}
		m, err := manifest.LoadOrFetch(r.cfg.ManifestClient, r.cfg.ManifestRoot, mod.ID, r.cfg.ManifestTTL)
		if err != nil {
			r.noteUnconverged("reconciler:fetch_manifest", mod.ID, fmt.Errorf("module %s: %w", mod.ID, err))
			continue
		}
		if m.Digest == "" {
			r.noteUnconverged("reconciler:no_digest", mod.ID, fmt.Errorf("module %s has no digest (not published)", mod.ID))
			continue
		}
		desired = append(desired, mount.Module{
			ID:           mod.ID,
			Digest:       m.Digest,
			Priority:     m.EffectivePriority,
			FsverityRoot: m.FsverityRootHash,
		})
		manifests[mod.ID] = m
	}

	// Take the state lock so CLI attach/detach can't race the reconciler.
	unlock, err := mount.Lock(r.cfg.StatePath)
	if err != nil {
		r.lastError = fmt.Errorf("acquire state lock: %w", err)
		return r.lastError
	}
	defer unlock()

	current, err := mount.LoadState(r.cfg.StatePath)
	if err != nil {
		r.lastError = fmt.Errorf("load state: %w", err)
		return r.lastError
	}

	// Captured before anything below mutates current.AttachedModules.
	// ComposeForPivot doesn't persist a state.json at boot, so on the
	// FIRST reconcile tick after a pivot boot, current is empty and every
	// boot module shows up in toAttach even though its files are ALREADY
	// part of the boot union — hotReconcileIfNeeded must not copy on that
	// baseline tick (see its doc comment). Tick 2+ has real prior state
	// (RunOnce SaveState's at the end of every cycle), so stateWasEmpty
	// correctly reflects "is this a genuine post-boot change".
	stateWasEmpty := len(current.AttachedModules) == 0

	toAttach, toDetach := mount.Reconcile(current, desired)

	// Detect already-attached modules whose manifest content changed
	// since the last attach. Reconcile() above only returns new mounts
	// in toAttach (digest-based diff against current.AttachedModules);
	// it doesn't notice manifest-only edits — a new services: entry,
	// updated start_command, sudoers grant added, etc. Without the
	// re-attach pass below, those edits silently never propagate to
	// the on-host systemd units, and the agent looks healthy from the
	// platform's view (mount + heartbeat both green) while quietly
	// running stale config. Discovered 2026-05-25 via the qemu-guest-
	// agent dogfood — see claude_code.agent_reattach_gap memory.
	//
	// Implementation: per-module SHA256 of the manifest's services
	// block, persisted across agent restarts in State.LastAttached
	// ManifestHashes. Diff each desired-and-currently-mounted module's
	// fresh hash against the stored value; mismatches go into
	// toReattach. AttachServices itself is already idempotent on
	// unchanged unit content, so the cost of a false-positive re-
	// attach is bounded (file content compare + N idempotent systemctl
	// start calls); avoiding that cost is what the hash check buys.
	if current.LastAttachedManifestHashes == nil {
		current.LastAttachedManifestHashes = map[string]string{}
	}
	attachedNow := map[string]bool{}
	for _, m := range current.AttachedModules {
		attachedNow[m.ID] = true
	}
	toReattach := make(mount.ModuleStack, 0)
	for _, mod := range desired {
		if !attachedNow[mod.ID] {
			continue // either freshly attaching (handled below) or not yet pulled
		}
		mf, ok := manifests[mod.ID]
		if !ok {
			continue
		}
		fresh := mf.ServicesHash()
		if current.LastAttachedManifestHashes[mod.ID] != fresh {
			toReattach = append(toReattach, mod)
		}
	}

	if r.cfg.DryRun {
		r.lastReconcileAt = time.Now()
		r.lastError = nil
		return nil
	}

	// Pull + verify + mount every new module's erofs blob BEFORE detaching
	// anything (see prefetchNewArtifacts doc). Must run before the detach
	// loop below — that ordering is the entire point of this call.
	r.prefetchNewArtifacts(ctx, toAttach)

	// Refuse detaches that would take down this node's own control plane
	// (see selfhost.go). Applied HERE, before both the detach loop and the
	// state bookkeeping below, so a refused module stays in
	// current.AttachedModules and is simply re-proposed — and re-refused —
	// on later ticks, rather than being recorded as detached while it is
	// still running.
	toDetach = r.filterUnsafeDetaches(toDetach, toAttach, manifests)

	// Inventory the outgoing versions BEFORE the detach loop unmounts them.
	// This is the only window in which the old trees are still readable, and
	// without their path sets a hot-reconcile cannot tell "the new version
	// dropped this file" from "this file was never ours" — which is why
	// deletions were originally out of scope. See hotprune.go.
	outgoingPaths := r.captureOutgoingPaths(toDetach, toAttach, manifests)

	// Same pre-unmount window, other half of the split: inventory modules
	// LEAVING the composition (no same-ID successor) for the deferred
	// leaver prune. See hotleaver.go for the tick-by-tick contract.
	leavers := r.captureLeaverInventories(toDetach, toAttach, manifests)

	// Detaches first, in reverse priority (highest priority unmounted first
	// so dependency stacks come down cleanly).
	detachStack := mount.ModuleStack(toDetach).SortByPriority()
	for i := len(detachStack) - 1; i >= 0; i-- {
		mod := detachStack[i]
		if err := r.detachModule(ctx, current, mod, manifests); err != nil {
			r.cfg.OnError("reconciler:detach", fmt.Errorf("module %s: %w", mod.ID, err))
			// Continue — best-effort detach; partial failure shouldn't block other detaches.
		}
	}

	r.writePendingPrunes(leavers)

	// Render /etc/passwd, /etc/group, /etc/shadow, /etc/gshadow from
	// the post-detach manifest set BEFORE any attach kicks off systemd
	// units that reference platform-managed users via `User=`. Sudoers
	// follows so any grant referencing the just-rendered users is in
	// place before service start. Both renderers are idempotent and
	// run every reconcile tick — atomic writes are no-ops if contents
	// match.
	manifestsSlice := make([]*manifest.Manifest, 0, len(manifests))
	for _, m := range manifests {
		manifestsSlice = append(manifestsSlice, m)
	}
	identitySet, conflicts := etcidentity.Collect(manifestsSlice)
	for _, c := range conflicts {
		r.cfg.OnError("reconciler:identity_conflict",
			fmt.Errorf("%s %q kept=%d dropped=%d (source=%s)",
				c.Kind, c.Name, c.KeptValue, c.DroppedValue, c.SourceModule))
	}
	if err := etcidentity.Apply(identitySet); err != nil {
		r.cfg.OnError("reconciler:identity_write", err)
	}
	// Make the filesystem agree with the passwd we just rendered: managed
	// home dirs must be owned by the user etcidentity declared (uid/gid =
	// platform source of truth) and /home must stay traversable, else sshd
	// and any unprivileged service with HOME there break. Idempotent.
	etcidentity.ReconcileHomeOwnership(identitySet, "", r.cfg.OnError)
	if err := etcsudoers.Apply(etcsudoers.CollectFromManifests(manifestsSlice)); err != nil {
		r.cfg.OnError("reconciler:sudoers_write", err)
	}

	// Node-wide egress enforcement, same pattern as identity/sudoers just
	// above: one shared nftables OUTPUT chain governs the WHOLE node, so it
	// must reflect the UNION of every currently-desired module's declared
	// policy, recomputed fresh from the same manifestsSlice every tick —
	// never a single module's own Policy.Apply, which would let whichever
	// module happens to reconcile last silently clobber every sibling's
	// intent (see security.UnionEgressPolicy's doc comment for the full
	// history of that bug).
	egressPolicies := make([]*security.Policy, 0, len(manifestsSlice))
	for _, m := range manifestsSlice {
		egressPolicies = append(egressPolicies, buildPolicy(m))
	}
	egressAllow, egressEnforced := security.UnionEgressPolicy(egressPolicies)
	if egressEnforced {
		var protectedHosts []string
		if h := hostFromURL(r.cfg.PlatformURL); h != "" {
			// The agent's own control-plane URL host must stay reachable
			// regardless of any module's policy — without this, a
			// restrictive module attaching would firewall the agent off
			// from its own parent on the very next tick (dial i/o timeout
			// after the chain installs).
			protectedHosts = append(protectedHosts, h)
		}
		// Backend-configured hosts (account settings / SiteSetting -- see
		// Api::V1::System::NodeApi::ModulesController#protected_egress_hosts)
		// that must ALSO always be reachable regardless of module policy,
		// e.g. a hub's own Gitea host. Fetched fresh every tick alongside
		// the module list, so a config change (or that host's IP changing)
		// takes effect on the next reconcile with no agent restart and no
		// module rebuild -- the alternative of baking a static IP into a
		// module manifest was rejected as exactly the kind of real-hostname-
		// in-tracked-source coupling this project avoids.
		protectedHosts = append(protectedHosts, assignmentMeta.ProtectedEgressHosts...)
		if err := security.ApplyEgressAllowlistWithProtected(ctx, r.cfg.MountRunner, egressAllow, protectedHosts); err != nil {
			r.cfg.OnError("reconciler:egress", err)
		}
	} else {
		// No currently-desired module declared an egress policy this tick
		// (e.g. the one module that did was just detached) — best-effort
		// teardown so a stale restrictive chain never lingers past the
		// module that asked for it. Error ignored deliberately: "no such
		// chain" is the common, expected case.
		_ = security.RemoveEgressAllowlist(ctx, r.cfg.MountRunner)
	}

	// Reassert the platform-assigned hostname every reconcile tick — live
	// /etc/hostname + the running kernel hostname — the same way the agent
	// owns /etc/passwd. Idempotent; a no-op when no authoritative source is
	// present this boot (e.g. a non-QEMU/cloud node with no instance_name
	// fw-cfg, where the hostname is set by cloud-init and left untouched here).
	if name := desiredHostname(); name != "" {
		changed, err := etcidentity.ApplyHostname("", name, true)
		switch {
		case err != nil:
			r.cfg.OnError("reconciler:hostname_write", err)
		case changed:
			// The announced-hostname drop-in ApplyHostname just wrote only
			// applies to the NEXT DHCP request, and this boot's lease was
			// already taken in the initramfs while the hostname was still
			// "localhost". On a fleet whose DHCP server publishes DNS from the
			// client-supplied hostname, the node's own record therefore stays
			// wrong until the lease renews — an hour here — and that is exactly
			// the window in which the agent must heartbeat to bless a boot slot,
			// promote a pending composition and sync operator SSH keys.
			//
			// `changed` is true once per boot (the composed root is fresh, so
			// the drop-in is always absent on the first tick), which is the
			// correct cadence: re-announce immediately, then never churn.
			if rerr := RenewDHCPLeases(ctx, r.cfg.MountRunner); rerr != nil {
				r.cfg.OnError("reconciler:dhcp_renew", rerr)
			}
		}
	}

	// Attaches in priority order (low → high). Walks toAttach (new
	// mounts: fresh erofs pull + verify + mount + AttachServices) and
	// toReattach (already-mounted but manifest-changed: skips the pull/
	// mount via attachModule's idempotency, re-runs AttachServices to
	// pick up the new units). Each successful attach refreshes the
	// per-module manifest hash so the next cycle's diff sees no drift.
	// Reaching the compose stage re-opens the verdict: a failure recorded on an
	// earlier pass must not outlive a pass that composed cleanly.
	r.composeFailed.Store(false)

	// Modules whose live materialization this pass refused. Rebuilt from
	// nothing every pass for the same reason convergeFailures is: it must
	// describe the pass that just ran, never an older one — a module converges
	// off the set simply by materializing on a later tick. A set (not a slice)
	// because a module whose digest AND services hash both changed appears in
	// toAttach and toReattach in the SAME tick, so hotReconcileIfNeeded can
	// refuse it twice. Written into State.UnmaterializedModules below, after
	// the detach filter, so it can never name a module that is no longer
	// attached.
	unmaterialized := map[string]bool{}
	attachStack := mount.ModuleStack(toAttach).SortByPriority()
	for _, mod := range attachStack {
		mf, ok := manifests[mod.ID]
		if !ok {
			r.noteUnconverged("reconciler:missing_manifest", mod.ID, fmt.Errorf("module %s: manifest not loaded", mod.ID))
			r.composeFailed.Store(true)
			continue
		}
		if err := r.attachModule(ctx, mod, mf); err != nil {
			r.noteUnconverged("reconciler:attach", mod.ID, fmt.Errorf("module %s: %w", mod.ID, err))
			r.composeFailed.Store(true)
			continue
		}
		current.AttachedModules = append(current.AttachedModules, mod)
		current.LastAttachedManifestHashes[mod.ID] = mf.ServicesHash()
		if r.hotReconcileIfNeeded(mod, mf, stateWasEmpty, outgoingPaths[mod.ID], desired) {
			// The stamp above is what the reattach gate compares, so leaving
			// it in place after a refused materialization tells the next tick
			// this module is fully synced when it is not. Clear it to re-queue.
			// The module STAYS in AttachedModules — the erofs layer really is
			// attached; only the file copy was refused. That is precisely why
			// it must ALSO be recorded as unmaterialized: the heartbeat reads
			// AttachedModules, and without this it would report the new digest
			// as running while the live root still serves the old files.
			delete(current.LastAttachedManifestHashes, mod.ID)
			unmaterialized[mod.ID] = true
		}
	}

	// Re-attach loop for manifest-only changes. attachModule is
	// idempotent on its mount + cosign + fs-verity + policy steps
	// (cached results return immediately) — the meaningful work here is
	// the AttachServices call inside, which writeIfChanged-s each unit
	// file and runs daemon-reload only when at least one wrote.
	for _, mod := range mount.ModuleStack(toReattach).SortByPriority() {
		mf, ok := manifests[mod.ID]
		if !ok {
			continue
		}
		if err := r.attachModule(ctx, mod, mf); err != nil {
			r.noteUnconverged("reconciler:reattach", mod.ID, fmt.Errorf("module %s: %w", mod.ID, err))
			continue
		}
		current.LastAttachedManifestHashes[mod.ID] = mf.ServicesHash()
		if r.hotReconcileIfNeeded(mod, mf, stateWasEmpty, outgoingPaths[mod.ID], desired) {
			// Same re-queue as the attach loop: a refused materialization must
			// not leave a stamp claiming this manifest is materialized, and
			// must not leave the heartbeat claiming it is running.
			delete(current.LastAttachedManifestHashes, mod.ID)
			unmaterialized[mod.ID] = true
		}
	}

	// Deferred leaver prunes — after both attach loops so every desired
	// module's tree is mounted before any surviving-layer resolution.
	r.processPendingPrunes(desired)

	// Filter out detached modules from current — both from the attached
	// list and from the manifest-hash map (so a later re-add doesn't
	// see a stale hash and skip the initial attach).
	if len(toDetach) > 0 {
		detached := make(map[string]bool, len(toDetach))
		detachedIDs := make(map[string]bool, len(toDetach))
		for _, m := range toDetach {
			detached[m.Digest] = true
			detachedIDs[m.ID] = true
		}
		filtered := current.AttachedModules[:0]
		for _, m := range current.AttachedModules {
			if !detached[m.Digest] {
				filtered = append(filtered, m)
			}
		}
		current.AttachedModules = filtered
		for id := range detachedIDs {
			delete(current.LastAttachedManifestHashes, id)
		}
	}

	// Compose the overlay union at SysRoot from all attached modules
	// in priority order. overlayfs lower-dir is highest-priority-first
	// (LowerDirString handles the reversal). On a fresh tick this is a
	// new mount; on subsequent ticks with stack changes this remounts
	// with a new lowerdir (live remount where supported, full
	// umount+mount fallback otherwise).
	//
	// Skipped when no modules are attached — the sysroot has nothing
	// to union and overlay's lowerdir requires at least one entry.
	if !r.cfg.DryRun && len(current.AttachedModules) > 0 {
		if lifecycle.PivotAwareRootMode() == lifecycle.RootModeNative {
			// Pivot-booted node: / is ALREADY the composed module union
			// (switch_root'd into it at boot). Re-mounting a second union at
			// /sysroot here creates two overlays sharing this live root's
			// upperdir+workdir — the kernel's "upperdir/workdir is in-use as
			// upperdir/workdir of another mount … undefined behavior" warning
			// (identity writes land in one mount, services read through the
			// other). A post-pivot stack change can't extend /'s lowerdir
			// without a reboot (reboot_required semantics), so the shadow
			// remount is pure downside. Treat / as the mounted union.
			current.UnionMounted = true
		} else {
			overlay := &mount.Overlay{Layout: r.cfg.Layout, Runner: r.cfg.MountRunner}
			if err := overlay.MountUnion(ctx, mount.ModuleStack(current.AttachedModules)); err != nil {
				r.noteUnconverged("reconciler:union_mount", "", err)
				r.composeFailed.Store(true)
				current.UnionMounted = false
			} else {
				current.UnionMounted = true
			}
		}
	}

	// Record which of the still-attached modules this pass could not
	// materialize, so buildHeartbeat can leave their digests out of the
	// reported running set. Intersected with AttachedModules deliberately: the
	// detach filter above may have dropped a module the loops touched, and a
	// module that is not attached at all is already absent from the report —
	// naming it here would be a stale claim rather than an honest one. Sorted
	// so a no-change pass rewrites byte-identical state.
	current.UnmaterializedModules = nil
	if len(unmaterialized) > 0 {
		// Deduped: a refused detach (filterUnsafeDetaches) can leave two
		// digests of ONE module id attached at once, and a module id repeated
		// in the reported set would read as two stuck modules.
		listed := map[string]bool{}
		for _, m := range current.AttachedModules {
			if unmaterialized[m.ID] && !listed[m.ID] {
				listed[m.ID] = true
				current.UnmaterializedModules = append(current.UnmaterializedModules, m.ID)
			}
		}
		sort.Strings(current.UnmaterializedModules)
	}

	if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
		r.lastError = fmt.Errorf("save state: %w", err)
		return r.lastError
	}

	r.lastReconcileAt = time.Now()
	r.lastError = nil

	// Stage the desired set for the NEXT boot. This is the post-pivot half of the
	// pending-compose mechanism: we are running, healthy enough to have completed
	// a reconcile, and — unlike the pre-pivot compose — we can actually reach the
	// platform. On a self-hosted control plane this is the only moment the node
	// ever learns what it is supposed to be running.
	r.stagePendingCompose(desiredModules, manifests, assignmentMeta)
	return nil
}

// stagePendingCompose records the currently-desired module set so the next boot
// can compose it even though its own pre-pivot fetch will fail.
//
// It stages ONLY when the desired set differs from what this boot actually
// composed, and only when every data module's blob is already in the local
// cache — a staged set whose blobs are missing would compose into a root that
// cannot mount, and the pre-pivot side has no network to fetch them with.
//
// Best-effort throughout: this is an optimisation for the next boot, never a
// reason to fail the current reconcile.
func (r *Reconciler) stagePendingCompose(assigned []AssignedModule, manifests map[string]*manifest.Manifest, meta AssignmentMeta) {
	bc, err := LoadBreadcrumb(BootBreadcrumbPath)
	if err != nil {
		return // no breadcrumb (non-pivot node, or compose wrote none) — nothing to compare against
	}

	mods := make([]LKGModule, 0, len(assigned))
	for _, mod := range assigned {
		lm := LKGModule{ID: mod.ID, Name: mod.Name, EffectivePriority: mod.EffectivePriority,
			HasDataFile: mod.HasDataFile, Variety: mod.Variety}
		if mod.HasDataFile {
			m, ok := manifests[mod.ID]
			if !ok || m.Digest == "" {
				return // incomplete view of the desired set — never stage a partial one
			}
			// The blob must already be local: the pre-pivot consumer cannot fetch.
			if _, statErr := os.Stat(r.cfg.Layout.ModuleCachePath(m.Digest)); statErr != nil {
				return // not pulled yet; a later reconcile will stage once it is
			}
			lm.EffectivePriority = m.EffectivePriority
			lm.Digest = m.Digest
			if raw, mErr := json.Marshal(m); mErr == nil {
				lm.Manifest = raw
			}
		}
		mods = append(mods, lm)
	}
	if len(mods) == 0 {
		return
	}
	if sameComposition(bc.Modules, mods) {
		return // already running exactly this; nothing to stage
	}
	// Compare against what is ALREADY staged, not just against what booted.
	// Without this, every reconcile tick (60s) rewrites the file with a
	// zero-valued Attempts — which silently erases the exhaustion cap, so a set
	// that keeps the platform serving but never passes the health gate would
	// retry forever across reboots instead of being abandoned after
	// PendingMaxTries. It also fsync'd /persist every minute for nothing.
	attempts := 0
	if existing, err := LoadPendingCompose(PendingComposePath); err == nil {
		if sameComposition(existing.Set.Modules, mods) {
			// Same modules. Normally nothing to do — but the SiteSetting-delivered
			// health-gate config travels with the staged set, so an operator fixing
			// a bad gate URL would otherwise never reach an already-staged set: its
			// remaining attempt would retry against the same broken gate and burn
			// out. Refresh the metadata while PRESERVING the burned attempts, which
			// is what stops the exhaustion cap being reset.
			if existing.Set.AppHealth == (AppHealthCfg{
				URL:                 meta.AppHealthURL,
				RequiredConsecutive: meta.AppHealthRequiredConsecutive,
				PollIntervalSeconds: meta.AppHealthPollIntervalSeconds,
			}) && existing.Set.StalenessThresholdSeconds == meta.StalenessThresholdSeconds {
				return // identical set AND identical gate config — nothing to write
			}
			attempts = existing.Attempts
		}
	}

	pend := &PendingCompose{
		Set: BootLKG{
			ConfirmedAt:               time.Now().UTC(),
			Source:                    r.cfg.PlatformURL,
			Hostname:                  meta.Hostname,
			StalenessThresholdSeconds: meta.StalenessThresholdSeconds,
			AppHealth: AppHealthCfg{
				URL:                 meta.AppHealthURL,
				RequiredConsecutive: meta.AppHealthRequiredConsecutive,
				PollIntervalSeconds: meta.AppHealthPollIntervalSeconds,
			},
			// Freeze the privileged allowlist with the staged set so a cold
			// FromPending boot enforces the gate against it (IMP-01a02f70-20b1,
			// F2) — critical on self-hosted nodes whose only capture source is
			// this staging path.
			PrivilegedModuleIDs:       meta.PrivilegedModuleIDs,
			PrivilegedAllowlistFrozen: true,
			Modules:                   mods,
		},
		StagedAt: time.Now().UTC(),
		Attempts: attempts,
		Reason:   "assigned-module set differs from the composed set",
	}
	if err := WritePendingCompose(PendingComposePath, pend); err != nil {
		r.cfg.OnError("reconciler:stage_pending_compose", err)
		return
	}
	r.cfg.OnError("reconciler:staged_pending_compose", fmt.Errorf(
		"staged %d-module composition for the next boot (was %d) — it will be tried once, "+
			"with the frozen LKG still underneath", len(mods), len(bc.Modules)))
}

// sameComposition compares two module sets by (id, digest) AND by the manifest
// fields that change what a module RUNS, order-insensitively.
//
// Digest alone is not enough. The agent renders systemd units, users, groups
// and security policy from the manifest, so a build that adds a SERVICE changes
// the node's behaviour while mounting a blob whose digest may be unchanged (or
// whose digest changed for unrelated reasons). Treating that as "same
// composition" means the new service is never staged and never runs — the
// delivery looks complete because the files are there. Confirmed live
// 2026-07-26: reverse-proxy-traefik shipped a new restore-dynamic oneshot whose
// unit was never created, on the sibling lkgretarget path with the identical
// blind spot.
//
// Cosmetic churn is still ignored, which is what the original comment here was
// protecting: priority, description, display names and the rest do not change
// what runs, and restaging on them would burn the attempt budget for nothing.
// behaviouralManifestKey draws that line explicitly.
func sameComposition(a, b []LKGModule) bool {
	if len(a) != len(b) {
		return false
	}
	type sig struct{ digest, manifest string }
	seen := make(map[string]sig, len(a))
	for _, m := range a {
		seen[m.ID] = sig{m.Digest, behaviouralManifestKey(m.Manifest)}
	}
	for _, m := range b {
		s, ok := seen[m.ID]
		if !ok || s.digest != m.Digest {
			return false
		}
		if s.manifest != behaviouralManifestKey(m.Manifest) {
			return false
		}
	}
	return true
}

// behaviouralManifestFields are the manifest keys that decide what a module
// RUNS on the node, as opposed to how it is described. Everything outside this
// set is cosmetic for staging purposes.
//
//	services  -> systemd units (name, exec, deps, health, user)
//	users     -> /etc/passwd entries the agent reconciles
//	groups    -> /etc/group entries
//	security  -> capability/userns/egress drop-ins
//	sudoers   -> /etc/sudoers.d grants
//	init      -> init_start/stop/restart lifecycle hooks
var behaviouralManifestFields = []string{"services", "users", "groups", "security", "sudoers", "init"}

// behaviouralManifestKey returns a stable digest over just those fields. Empty
// string for an absent or unparseable manifest, so a module without one
// compares equal to another without one rather than restaging every tick.
//
// Uses encoding/json round-tripping for canonicalisation: Go marshals map keys
// in sorted order, so two manifests differing only in key order or whitespace
// produce the same key and do NOT trigger a restage.
func behaviouralManifestKey(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var man map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber() // don't let 1 and 1.0 differ across a float round-trip
	if err := dec.Decode(&man); err != nil {
		// Unparseable: fall back to the raw bytes so a corrupt manifest still
		// compares consistently with itself instead of silently matching
		// everything.
		sum := sha256.Sum256(raw)
		return "raw:" + hex.EncodeToString(sum[:8])
	}
	subset := make(map[string]any, len(behaviouralManifestFields))
	for _, k := range behaviouralManifestFields {
		if v, ok := man[k]; ok {
			subset[k] = v
		}
	}
	if len(subset) == 0 {
		return ""
	}
	encoded, err := json.Marshal(subset)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(encoded)
	return hex.EncodeToString(sum[:8])
}

// mountModuleArtifact pulls the module's erofs blob, verifies it (cosign bundle
// + fs-verity digest), and loop-mounts it at /run/powernode/modules/<digest>.
// Idempotent — MountModule no-ops when already mounted. Shared by attachModule
// (cloud_init reconcile, which then applies policy + starts units) and
// ComposeForPivot (direct_kernel boot, which composes + enables native units).
func (r *Reconciler) mountModuleArtifact(ctx context.Context, mod mount.Module) error {
	ref := &oci.ModuleArtifactRef{
		ModuleID:    mod.ID,
		Digest:      mod.Digest,
		DownloadURL: fmt.Sprintf("/api/v1/system/node_api/files/modules/%s", mod.ID),
		Size:        0,
	}
	cfsPath, bundlePath, err := r.cfg.Puller.Pull(ref)
	if err != nil {
		return fmt.Errorf("pull: %w", err)
	}
	if err := r.cfg.Verifier.VerifyBlob(ctx, cfsPath, bundlePath); err != nil {
		return fmt.Errorf("verify cosign: %w", err)
	}
	if r.cfg.Fsverity != nil {
		// mod.FsverityRoot, NOT mod.Digest: Digest is the sha256 of the blob
		// bytes, FsverityRoot is the kernel's Merkle-tree root over the same
		// file. Passing Digest here compared two unrelated hashes, so every
		// module mount would have failed the moment fs-verity was enabled.
		// Dormant until now only because cfg.Fsverity is nil by default.
		if mod.FsverityRoot == "" {
			// Fail closed. A configured verifier with nothing to verify against
			// is a silent bypass, which is worse than refusing the mount: the
			// operator turned fs-verity ON and would otherwise get unverified
			// modules while believing they were protected.
			return fmt.Errorf("verify fs-verity: module %s has no fsverity_root_hash published; "+
				"refusing to mount unverified while fs-verity is enabled", mod.ID)
		}
		if err := r.cfg.Fsverity.VerifyDigest(ctx, cfsPath, mod.FsverityRoot); err != nil {
			return fmt.Errorf("verify fs-verity: %w", err)
		}
	}
	// Direct loop mount, no extraction: `mount -t erofs -o loop,ro`. The kernel
	// allocates the loop device automatically. The overlay union (composed at
	// Layout.SysRoot) reads these per-module mountpoints as read-only lower-dirs
	// in priority order.
	if err := mount.MountModule(ctx, r.cfg.MountRunner, r.cfg.Layout, mod); err != nil {
		return fmt.Errorf("mount erofs: %w", err)
	}
	return nil
}

// prefetchNewArtifacts pulls, verifies, and mounts every toAttach module's
// erofs blob before RunOnce detaches anything. Fixes a circular dependency:
// some modules' own content-serving API depends on the very service
// instance being replaced — e.g. a self-hosted platform's own hub-backend
// Rails process serves /api/v1/system/node_api/files/modules/:id, which
// mountModuleArtifact's Puller.Pull fetches through. Without this, a
// same-tick version bump (old digest in toDetach, new digest in toAttach,
// same module ID) stops the old service in the detach loop, and the new
// blob's pull — attempted afterward, in the attach loop — 502s against the
// now-dead service, permanently wedging the reconcile with no module
// mounted at all. Observed live, 2026-07-20, ops-hub's self-hosted
// hub-backend/extension-system publish.
//
// mountModuleArtifact's mount step is idempotent (content-addressed by
// digest, IsMountpoint-checked first — see erofs.go), so calling it here
// and then again inside the normal attachModule() call later in this same
// tick is safe and cheap: the second call finds the mountpoint already
// populated and proceeds straight to policy + AttachServices.
//
// Best-effort: a prefetch failure here is surfaced via OnError but is not
// fatal to the tick — detach still proceeds, and the normal attachModule()
// call later will attempt (and fail again, now correctly attributed)
// rather than silently skipping the module.
func (r *Reconciler) prefetchNewArtifacts(ctx context.Context, toAttach mount.ModuleStack) {
	for _, mod := range toAttach {
		if err := r.mountModuleArtifact(ctx, mod); err != nil {
			r.cfg.OnError("reconciler:prefetch", fmt.Errorf("module %s: %w", mod.ID, err))
		}
	}
}

// attachModule pulls + verifies + mounts a single module, then applies security
// policy and starts its units in the cloud_init (RootDirectory chroot) model.
func (r *Reconciler) attachModule(ctx context.Context, mod mount.Module, mf *manifest.Manifest) error {
	if err := r.mountModuleArtifact(ctx, mod); err != nil {
		return err
	}

	// Apply PER-MODULE security policy (MAC + seccomp + capabilities).
	// SeccompProfile is a path inside the module's mounted root; the
	// drop-in for each unit is written here so subsequent systemctl start
	// picks it up. Egress is NOT applied here — see Policy.Apply's doc
	// comment; it's unioned across all attached modules once per RunOnce
	// tick (below, alongside the etcidentity/etcsudoers union step).
	policy := buildPolicy(mf)
	if policy.Privileged && !privilegedApproved(mod.ID, r.privilegedAllow) {
		// The module REQUESTS privileged (all confinement off) but the operator
		// has not GRANTED it via privileged_module_ids. Refuse the attach
		// outright — running it unconfined on an unapproved request is exactly
		// the hole IMP-01a02f70-20b1 named. Fatal + loud: the attach loop marks
		// the pass unconverged, so the platform sees a convergence failure
		// rather than a module silently running with no confinement.
		return fmt.Errorf(
			"module %s requests security.privileged=true (disables all on-node confinement) "+
				"but is not in the operator-approved privileged allowlist (privileged_module_ids); "+
				"refusing to attach it unconfined", mod.ID)
	}
	if errs := policy.Validate(); len(errs) > 0 {
		return fmt.Errorf("policy invalid: %v", errs)
	}
	if err := policy.Apply(ctx, r.cfg.MountRunner); err != nil {
		return fmt.Errorf("apply policy: %w", err)
	}
	if policy.SeccompProfile != "" {
		for _, unit := range mf.UnitNames() {
			if err := security.WriteSeccompDropIn(unit, policy.SeccompProfile); err != nil {
				r.cfg.OnError("reconciler:seccomp_dropin", fmt.Errorf("module %s unit %s: %w", mod.ID, unit, err))
			}
		}
	}
	// Capability bounding + ambient sets enforce via per-unit systemd
	// drop-ins (mirrors the seccomp pattern above). Privileged modules
	// skip this — they opt into ALL caps by design. We always write the
	// drop-in for non-privileged modules even when the allowlist is
	// empty, because an empty CapabilityBoundingSet= is the strictest
	// (and safest default) posture and an absent drop-in would inherit
	// systemd's full caps. Drop-in failures are non-fatal — surface via
	// OnError so the operator sees them; the service still starts with
	// whatever caps systemd's defaults give it.
	if !policy.Privileged {
		for _, unit := range mf.UnitNames() {
			if err := security.WriteCapabilityDropIn(unit, policy.Capabilities); err != nil {
				r.cfg.OnError("reconciler:capability_dropin",
					fmt.Errorf("module %s unit %s: %w", mod.ID, unit, err))
			}
		}
	}
	// User-namespace isolation (PrivateUsers=) enforces via a per-unit
	// systemd drop-in. UNLIKE seccomp (conditional on a profile path) we
	// ALWAYS write this drop-in to reflect policy.UserNamespace — that's the
	// only way the documented default (true) is actually enforced; an absent
	// drop-in would silently leave the unit in the host user namespace.
	// We write it for ALL modules, including Privileged ones: PrivateUsers
	// is orthogonal to the capability/MAC opt-out (it only remaps UID/GID
	// namespaces, never relaxing the bounding set or seccomp filter). A
	// module that genuinely needs the host user namespace (raw socket
	// access) sets `user_namespace: false` in its manifest, which yields
	// PrivateUsers=no here; Privileged is a separate, orthogonal opt-in.
	// Drop-in failures are non-fatal — surface via OnError; the service
	// still starts with whatever userns posture systemd's defaults give it.
	for _, unit := range mf.UnitNames() {
		if err := security.WriteUserNamespaceDropIn(unit, policy.UserNamespace); err != nil {
			r.cfg.OnError("reconciler:userns_dropin",
				fmt.Errorf("module %s unit %s: %w", mod.ID, unit, err))
		}
	}

	// P8.1 — Service lifecycle. lifecycle.AttachServices writes one
	// systemd unit file per system_module_services row, runs
	// daemon-reload, then starts services in topological order over
	// declared dependencies.
	//
	// Modules with an empty services list are content-only by design
	// (e.g. powernode-base-ruby ships the Ruby runtime that hub-backend
	// + hub-worker layer on top of, powernode-extension-system ships
	// Ruby code, powernode-hub-frontend ships static assets served by
	// reverse-proxy). For these, the mount itself is the contribution —
	// silent no-op is the right behavior. The detach path below mirrors
	// this: it skips DetachServices when Services is empty without
	// surfacing anything to OnError.
	if len(mf.Services) == 0 {
		return nil
	}
	// Boot-model-aware: the reconcile loop runs post-pivot on a hub
	// (module union IS /, render native) AND on cloud_init hosts (guest
	// OS is /, chroot into /sysroot). PivotAwareRootMode picks by whether
	// /persist reads as a distinct mount. A chroot-rendered unit on a
	// pivoted host stamps RootDirectory=/sysroot — which switch_root
	// already consumed — so the service never starts (the hub enrolls but
	// runs no app modules).
	if _, err := lifecycle.AttachServicesMode(ctx, r.cfg.MountRunner, mod.ID, mf.Services, lifecycle.PivotAwareRootMode()); err != nil {
		r.cfg.OnError("reconciler:attach_services",
			fmt.Errorf("module %s: %w", mod.ID, err))
	}

	return nil
}

// hotReconcileIfNeeded is called after a successful attachModule for BOTH
// freshly-attached (toAttach) and manifest-reattached (toReattach)
// modules. It closes the pivot-node file-hotreload gap described on
// SyncModuleFilesToRoot: a changed module's systemd units already
// hot-restart against new content via attachModule above, but on a pivot
// node the new content itself never lands in / (the union-skip block
// further down in RunOnce deliberately never re-extends /'s lowerdir
// post-boot) — without this, the restarted service silently keeps running
// the OLD files until a reboot.
//
// Gate, in order:
//   - DryRun / stateWasEmpty / nil manifest: nothing to do (see
//     stateWasEmpty's doc at its capture site above — tick 1 post-boot
//     must never hot-copy the whole base image as if it were new).
//   - Not a pivot node (pivotAwareRootMode() != RootModeNative): the
//     cloud_init model chroots units into /sysroot, which already gets a
//     full union remount on every attach — no gap to close there.
//   - RebootRequired: the module explicitly declares its files can't be
//     safely hot-swapped (base-os-ubuntu-noble is the canonical example —
//     it's the root OS layer itself). Surface a "reboot pending" signal
//     via OnError instead of copying, once per module per tick.
//   - Otherwise: copy the module's mounted erofs content onto the live
//     root. Errors surface via OnError; a quiet success (including
//     changed == 0, i.e. nothing had actually drifted) is not logged —
//     OnError is reserved for failures and there's no dedicated
//     benign/info-log hook in this package.
//
// Returns retryNeeded: true ONLY when the materialization was refused for a
// reason a later tick could resolve on its own. The caller clears the module's
// manifest-hash stamp in that case, which puts it back into toReattach next
// tick — see the reattach gate in RunOnce.
//
// It is deliberately NOT "anything other than complete success". A
// reboot_required module and a first-boot attach both decline to sync here and
// must return false: retrying either would re-enter toReattach on every tick
// forever, spamming signals without ever making progress, because nothing the
// reconciler does resolves them. Only the scratch-budget abort is genuinely
// transient — the space may exist next time.
func (r *Reconciler) hotReconcileIfNeeded(mod mount.Module, mf *manifest.Manifest, stateWasEmpty bool, oldPaths map[string]bool, desired mount.ModuleStack) (retryNeeded bool) {
	if r.cfg.DryRun || stateWasEmpty || mf == nil {
		return false
	}
	if pivotAwareRootMode() != lifecycle.RootModeNative {
		return false
	}
	if mf.RebootRequired {
		r.noteUnconverged("reconciler:reboot_pending", mod.ID,
			fmt.Errorf("module %s changed but reboot_required=true; a reboot (or `powernode-agent soft-recompose --execute`) is needed to apply", mod.ID))
		return false
	}
	srcDir := r.cfg.Layout.ModuleMountPath(mod.Digest)
	dstRoot := filepath.Join(r.cfg.Layout.Root, "/")
	res, err := SyncModuleFiles(srcDir, dstRoot, SyncOptions{
		HigherLayers: r.higherPriorityLayerDirs(desired, mod.ID),
		MinFreeBytes: r.scratchMinFreeBytes(),
	})
	if errors.Is(err, ErrScratchBudget) {
		// The materialization would exhaust the scratch tmpfs backing the
		// live root's upperdir. Surface it as its own signal so the
		// operator can act on it distinctly from an ordinary copy failure.
		//
		// RETURN — never fall through to the prune below. The prune
		// rewrites restored files onto the very filesystem this sync just
		// refused to write a single byte to, and its whiteouts are
		// themselves upperdir entries (one real incident produced 14,494
		// of them from a single pass). Refusing to copy and then deleting,
		// on a scratch that is already full, is the worst of both.
		r.noteUnconverged("reconciler:recompose_budget", mod.ID,
			fmt.Errorf("module %s: live materialization aborted, skipping this module's prune (`powernode-agent soft-recompose --execute` applies it without the scratch limit): %w", mod.ID, err))
		// RETRY. The caller stamps LastAttachedManifestHashes before calling
		// us, so without this the reattach gate sees a matching hash on every
		// later tick and the partial sync is never attempted again — the
		// signal above fires once and goes quiet, reading as resolved rather
		// than stuck. Clearing the stamp re-queues the module so it converges
		// once the scratch has room.
		//
		// Note this does NOT repair the split the abort leaves behind:
		// fs.SkipAll stops a lexically-ordered walk, so the module sits at an
		// arbitrary alphabetical boundary with its units already restarted
		// against a mixture of old and new files until a retry completes.
		// Making the materialization atomic is a separate change.
		return true
	}
	if err != nil {
		r.noteUnconverged("reconciler:hot_reconcile", mod.ID, fmt.Errorf("module %s: %w", mod.ID, err))
	}
	// Same composition smell hot_prune_contested surfaces: two modules
	// claim one path. Here the higher-priority layer's content was kept,
	// which is correct — but the operator should still see the contention.
	if res.Contested > 0 {
		r.cfg.OnError("reconciler:hot_sync_contested",
			fmt.Errorf("module %s: %d path(s) it ships are also shipped by a higher-priority module; the higher layer's content was kept", mod.ID, res.Contested))
	}

	// Removals. Only reachable when the previous version's tree was
	// inventoried before it was unmounted; a first attach (nothing
	// outgoing) has no baseline and correctly prunes nothing.
	if len(oldPaths) == 0 {
		return false
	}
	pruneRes, pruneErr := PruneRemovedFiles(PruneOptions{
		OldPaths:        oldPaths,
		NewErofsDir:     srcDir,
		DstRoot:         dstRoot,
		SurvivingLayers: r.survivingLayerDirs(desired, mod.ID),
		Protected:       mf.ProtectedSpec,
	})
	if pruneErr != nil {
		r.cfg.OnError("reconciler:hot_prune", fmt.Errorf("module %s: %w", mod.ID, pruneErr))
	}
	// Restored means another module in the stack also claims a path this
	// one just dropped. That resolves correctly here, but two modules
	// owning one path is a composition smell the operator should see —
	// it is the shape that produced the shadowed-`go` defect this
	// mechanism was built after.
	if pruneRes.Restored > 0 {
		r.cfg.OnError("reconciler:hot_prune_contested",
			fmt.Errorf("module %s: %d path(s) it dropped are also provided by another module and were restored from it", mod.ID, pruneRes.Restored))
	}
	return false
}

// higherPriorityLayerDirs returns the mount dirs of every module in the
// desired composition with HIGHER effective priority than modID, highest
// first — the subset of the union that can out-rank modID on a contested
// path. Ties resolve the way SortByPriority orders them (ascending
// priority, then ID): a later position in the sorted stack is closer to
// the union top, so it counts as higher here too — divergence between the
// two orderings is exactly how a winner-resolution bug would creep back in.
func (r *Reconciler) higherPriorityLayerDirs(desired mount.ModuleStack, modID string) []string {
	sorted := desired.SortByPriority()
	self := -1
	for i, m := range sorted {
		if m.ID == modID {
			self = i
			break
		}
	}
	// self < 0 is load-bearing: without it the loop below treats EVERY
	// module as higher-priority. A top-of-stack module needs no special
	// case — the loop simply yields nothing.
	if self < 0 {
		return nil
	}
	dirs := make([]string, 0, len(sorted)-self-1)
	for i := len(sorted) - 1; i > self; i-- {
		d := r.cfg.Layout.ModuleMountPath(sorted[i].Digest)
		// An unmounted/empty higher layer must not be consulted: it would
		// resolve every contested path to "nobody else provides this" and
		// re-open the very shadowing bug this list exists to prevent.
		if !layerProvidesAnything(d) {
			continue
		}
		dirs = append(dirs, d)
	}
	return dirs
}

// scratchMinFreeBytes resolves the budget-guard floor: the configured
// value, else DefaultScratchMinFreeBytes.
func (r *Reconciler) scratchMinFreeBytes() uint64 {
	if r.cfg.ScratchMinFreeBytes > 0 {
		return r.cfg.ScratchMinFreeBytes
	}
	return DefaultScratchMinFreeBytes
}

// survivingLayerDirs returns the mount dirs of every module in the desired
// composition EXCEPT excludeID, ordered highest-priority first — the same
// order overlayfs resolves lower layers in (see mount.LowerDirString), so a
// path looked up through this list resolves to what the union would serve.
//
// Built from `desired` rather than the incrementally-populated
// current.AttachedModules because the attach loop calls this mid-flight:
// modules later in the stack are already mounted (prefetchNewArtifacts
// mounts every incoming blob before any detach) but not yet recorded, and
// consulting the partial list would miss legitimate providers and turn a
// restore into a removal.
func (r *Reconciler) survivingLayerDirs(desired mount.ModuleStack, excludeID string) []string {
	sorted := desired.SortByPriority()
	dirs := make([]string, 0, len(sorted))
	for i := len(sorted) - 1; i >= 0; i-- {
		if sorted[i].ID == excludeID {
			continue
		}
		d := r.cfg.Layout.ModuleMountPath(sorted[i].Digest)
		// A layer that is not serving content cannot authorise a deletion
		// (see layerProvidesAnything): including it would make paths it
		// should still provide look sole-owned.
		if !layerProvidesAnything(d) {
			continue
		}
		dirs = append(dirs, d)
	}
	return dirs
}

// captureOutgoingPaths inventories each superseded module version's file set
// while its erofs is STILL MOUNTED — the detach loop that follows unmounts
// it, and after that the old tree is unrecoverable without re-pulling the
// blob.
//
// Only versions with a same-ID successor are captured. A module leaving the
// composition entirely is a different operation with different semantics
// (its files come out on the next recompose, and removing them live would
// race an operator who is mid-reassignment), and a full detach of a large
// layer is exactly where an unnecessary walk would cost the most.
//
// reboot_required modules are skipped: their successor short-circuits in
// hotReconcileIfNeeded before it ever reaches the prune, so walking
// base-os-sized trees here would be pure waste.
func (r *Reconciler) captureOutgoingPaths(toDetach, toAttach mount.ModuleStack, manifests map[string]*manifest.Manifest) map[string]map[string]bool {
	if len(toDetach) == 0 || len(toAttach) == 0 {
		return nil
	}
	incoming := make(map[string]bool, len(toAttach))
	for _, m := range toAttach {
		incoming[m.ID] = true
	}
	out := make(map[string]map[string]bool)
	for _, mod := range toDetach {
		if !incoming[mod.ID] {
			continue // leaving the composition, not being replaced
		}
		if mf, ok := manifests[mod.ID]; ok && mf != nil && mf.RebootRequired {
			continue
		}
		tp, err := ModuleTreePaths(r.cfg.Layout.ModuleMountPath(mod.Digest))
		if err != nil {
			// A partial inventory would understate what the old version
			// shipped, which understates the removals — safe, but worth
			// surfacing. Drop it rather than prune from a partial baseline.
			r.cfg.OnError("reconciler:capture_outgoing",
				fmt.Errorf("module %s: %w", mod.ID, err))
			continue
		}
		out[mod.ID] = tp.Files
	}
	return out
}

// detachModule stops the module's units and unmounts it.
func (r *Reconciler) detachModule(ctx context.Context, current *mount.State, mod mount.Module, manifests map[string]*manifest.Manifest) error {
	// Look up the manifest for unit names — it may already be on disk
	// even though the platform no longer assigns the module.
	mf, ok := manifests[mod.ID]
	if !ok {
		mf, _ = manifest.LoadFromDisk(r.cfg.ManifestRoot, mod.ID)
	}
	// P8.1 — Service detach via lifecycle.DetachServices: reverse
	// topological stop + unit-file removal + daemon-reload. Content-only
	// modules (empty Services list — see attachModule for examples) or
	// stale on-disk manifests degrade to no-op silently here; there's
	// nothing to stop.
	if mf != nil && len(mf.Services) > 0 {
		if _, err := lifecycle.DetachServices(ctx, r.cfg.MountRunner, mod.ID, mf.Services); err != nil {
			r.cfg.OnError("reconciler:detach_services",
				fmt.Errorf("module %s: %w", mod.ID, err))
		}
	}
	// Unmount the module's erofs blob — UNLESS the live union still lists
	// it as a lower layer.
	//
	// The original reasoning here was that unmounting is safe because
	// "RunOnce reaps detached modules first, then rebuilds the overlay
	// with the remaining stack". That holds for the cloud_init model,
	// where the union lives at SysRoot and IS recomposed on every stack
	// change. It is false in exactly the mode that matters: on a pivot
	// node / IS the union, its lowerdir was fixed at mount time, and the
	// union-skip block further up deliberately never rebuilds it. So the
	// premise the unmount relied on never becomes true there, and
	// unmounting pulls a layer out from under the RUNNING root — every
	// file it provided stops resolving, with no error and no crash.
	//
	// Cost of the two mistakes is wildly asymmetric: keeping an unused
	// erofs mounted wastes one loop device until the next reboot, while
	// unmounting a referenced one silently strips content from a live
	// node (2026-08-07: the entire Go toolchain, GOROOT/src included).
	// So an unreadable mount table means SKIP, never proceed.
	if skip, why := r.unmountWouldStripLiveRoot(mod); skip {
		r.cfg.OnError("reconciler:unmount_skipped",
			fmt.Errorf("module %s: leaving erofs mounted — %s", mod.ID, why))
	} else if err := mount.UnmountModule(ctx, r.cfg.MountRunner, r.cfg.Layout, mod.Digest); err != nil {
		r.cfg.OnError("reconciler:unmount_module",
			fmt.Errorf("module %s: %w", mod.ID, err))
	}
	_ = current // current state held by caller; best-effort detach
	return nil
}

// unmountWouldStripLiveRoot reports whether unmounting mod's erofs would
// remove a layer the RUNNING root's overlay still references, and why.
//
// Only meaningful in native (pivot) mode: there / IS the union and its
// lowerdir is frozen at mount time. In chroot mode the union is remounted
// at SysRoot on every stack change, so a superseded layer is genuinely
// unreferenced by the time we get here and unmounting reclaims it.
//
// Fails CLOSED. If the mount table cannot be read, or the union cannot be
// parsed, the answer is "would strip" — see the asymmetry argument at the
// call site.
func (r *Reconciler) unmountWouldStripLiveRoot(mod mount.Module) (bool, string) {
	if pivotAwareRootMode() != lifecycle.RootModeNative {
		return false, ""
	}
	liveRoot := filepath.Join(r.cfg.Layout.Root, "/")
	dir := r.cfg.Layout.ModuleMountPath(mod.Digest)
	inUnion, err := mount.PathInLiveUnion(liveRoot, dir)
	if err != nil {
		return true, fmt.Sprintf("cannot read the live mount table to prove %s is unreferenced (%v); refusing to risk stripping the running root", dir, err)
	}
	if inUnion {
		return true, fmt.Sprintf("%s is still a lower layer of the live union at %s; unmounting it would remove its files from the running root", dir, liveRoot)
	}
	return false, ""
}

// hostFromURL parses a URL and returns the host (without port).
// Returns "" for invalid / empty URLs so callers can chain `if h != ""`
// without an extra nil check.
func hostFromURL(raw string) string {
	if raw == "" {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return ""
	}
	host := u.Hostname()
	return host
}

// buildPolicy constructs a security.Policy from the manifest's
// config["security"] block. Returns an empty policy when no security
// block is present.
func buildPolicy(m *manifest.Manifest) *security.Policy {
	// UserNamespace defaults to true per Policy's documented contract — an
	// omitted security.user_namespace must yield private-userns isolation,
	// not the Go zero-value (false). An explicit `user_namespace: false`
	// still parses to false via the assignment below.
	p := &security.Policy{UserNamespace: true}
	if m == nil || m.Config == nil {
		return p
	}
	sec, ok := m.Config["security"].(map[string]any)
	if !ok {
		return p
	}
	if caps, ok := sec["capabilities"].([]any); ok {
		for _, c := range caps {
			if s, ok := c.(string); ok {
				p.Capabilities = append(p.Capabilities, s)
			}
		}
	}
	if v, ok := sec["selinux_profile"].(string); ok {
		p.SELinuxProfile = v
	}
	if v, ok := sec["apparmor_profile"].(string); ok {
		p.AppArmorProfile = v
	}
	if v, ok := sec["seccomp_profile"].(string); ok {
		p.SeccompProfile = v
	}
	// EgressDeclared tracks raw KEY PRESENCE, not just a non-empty result —
	// `security: {egress_allow: []}` (claude-tmux's deliberate "restrict me
	// to the baseline") must still be distinguishable from a module with no
	// security block at all (which should never force node-wide enforcement
	// just by existing). See UnionEgressPolicy.
	if v, ok := sec["egress_allow"]; ok {
		p.EgressDeclared = true
		if list, ok := v.([]any); ok {
			for _, e := range list {
				if s, ok := e.(string); ok {
					p.EgressAllow = append(p.EgressAllow, s)
				}
			}
		}
	}
	if v, ok := sec["privileged"].(bool); ok {
		p.Privileged = v
	}
	if v, ok := sec["user_namespace"].(bool); ok {
		p.UserNamespace = v
	}
	return p
}

// LastReconcileAt is exposed for the heartbeat builder.
func (r *Reconciler) LastReconcileAt() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.lastReconcileAt
}

// AttachOne pulls + verifies + mounts a single module without
// running a full reconcile cycle. Used by the `attach` CLI for
// operator-driven hot-add of a debug module. Idempotent: if the
// module is already attached at the same digest, returns ok with
// status=already_attached.
func (r *Reconciler) AttachOne(ctx context.Context, moduleID string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	mf, err := manifest.LoadOrFetch(r.cfg.ManifestClient, r.cfg.ManifestRoot, moduleID, r.cfg.ManifestTTL)
	if err != nil {
		return "", fmt.Errorf("fetch manifest: %w", err)
	}
	if mf.Digest == "" {
		return "", fmt.Errorf("module %s has no digest (not published)", moduleID)
	}

	unlock, err := mount.Lock(r.cfg.StatePath)
	if err != nil {
		return "", fmt.Errorf("acquire state lock: %w", err)
	}
	defer unlock()

	current, err := mount.LoadState(r.cfg.StatePath)
	if err != nil {
		return "", fmt.Errorf("load state: %w", err)
	}

	for _, m := range current.AttachedModules {
		if m.ID == moduleID && m.Digest == mf.Digest {
			return "already_attached", nil
		}
	}

	mod := mount.Module{ID: moduleID, Digest: mf.Digest, Priority: mf.EffectivePriority, FsverityRoot: mf.FsverityRootHash}
	if err := r.attachModule(ctx, mod, mf); err != nil {
		return "", err
	}

	current.AttachedModules = append(current.AttachedModules, mod)
	if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
		return "", fmt.Errorf("save state: %w", err)
	}
	return "attached", nil
}

// DetachOne stops + unmounts a single module. Used by the `detach`
// CLI. Idempotent: if the module isn't currently attached, returns
// ok with status=already_detached.
func (r *Reconciler) DetachOne(ctx context.Context, moduleID string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	unlock, err := mount.Lock(r.cfg.StatePath)
	if err != nil {
		return "", fmt.Errorf("acquire state lock: %w", err)
	}
	defer unlock()

	current, err := mount.LoadState(r.cfg.StatePath)
	if err != nil {
		return "", fmt.Errorf("load state: %w", err)
	}

	idx := -1
	for i, m := range current.AttachedModules {
		if m.ID == moduleID {
			idx = i
			break
		}
	}
	if idx < 0 {
		return "already_detached", nil
	}

	manifests := map[string]*manifest.Manifest{}
	if mf, _ := manifest.LoadFromDisk(r.cfg.ManifestRoot, moduleID); mf != nil {
		manifests[moduleID] = mf
	}
	if err := r.detachModule(ctx, current, current.AttachedModules[idx], manifests); err != nil {
		return "", err
	}

	current.AttachedModules = append(current.AttachedModules[:idx], current.AttachedModules[idx+1:]...)
	if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
		return "", fmt.Errorf("save state: %w", err)
	}
	return "detached", nil
}

// FactoryConfig bundles the dependencies needed to build a Reconciler
// outside the long-lived service.Run path. Used by the `update`,
// `sync`, `attach`, `detach` CLIs which each construct a one-shot
// reconciler scoped to a single command invocation.
type FactoryConfig struct {
	ModulesClient  ModulesClient
	ManifestClient manifest.Client
	ManifestRoot   string
	Puller         PullerAPI
	Verifier       verify.Verifier
	Fsverity       *verify.FsVerifier
	MountRunner    mount.Runner
	Layout         mount.Layout
	StatePath      string
	DryRun         bool
	OnError        func(stage string, err error)
	// PlatformURL is recorded as the boot-LKG breadcrumb Source (the control
	// plane the compose fetched from). Purely informational for the snapshot.
	PlatformURL string
	// BreadcrumbSink — see ReconcilerConfig.BreadcrumbSink.
	BreadcrumbSink func(*BootComposedBreadcrumb)
}

// NewReconcilerForCLI builds a Reconciler suitable for one-shot CLI
// invocations. Differs from NewReconciler only in defaulting policy
// — CLIs typically want immediate-error-surfacing rather than
// background-loop graceful-degradation.
func NewReconcilerForCLI(cfg FactoryConfig) (*Reconciler, error) {
	return NewReconciler(ReconcilerConfig{
		ModulesClient:  cfg.ModulesClient,
		ManifestClient: cfg.ManifestClient,
		ManifestRoot:   cfg.ManifestRoot,
		Puller:         cfg.Puller,
		Verifier:       cfg.Verifier,
		Fsverity:       cfg.Fsverity,
		MountRunner:    cfg.MountRunner,
		Layout:         cfg.Layout,
		StatePath:      cfg.StatePath,
		Interval:       0, // not used for one-shot
		DryRun:         cfg.DryRun,
		OnError:        cfg.OnError,
		PlatformURL:    cfg.PlatformURL,
		BreadcrumbSink: cfg.BreadcrumbSink,
	})
}

// LastError returns the most recent reconcile-loop error (nil on
// success).
func (r *Reconciler) LastError() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.lastError
}

// ComposedOK reports that this boot has shown NO evidence of a broken module
// composition. It is the boot-confirm gate's other half, and its exact wording
// is the point.
//
// It deliberately does NOT require a SUCCESSFUL reconcile. The obvious version
// — "a pass completed with lastError == nil" — was written first and is wrong
// twice over.
//
// Wrong on what it catches: lastError is only ever set by fetching the assigned
// modules, taking the state lock, and loading or saving state. Every attach,
// re-attach, detach and union-mount failure is reported through OnError and the
// pass then stamps success regardless. A UKI whose module machinery is broken —
// precisely the /sbin-shadowing and module-overlay class this gate exists for —
// would have satisfied it and blessed.
//
// Wrong on what it blocks: three of those four sites need the PLATFORM. Gating
// a bless on them re-couples blessing to "can I reach the platform", which
// BootConfirmer's own header calls the wrong question. A node whose platform
// link, DNS, or mTLS identity is down for a whole boot could then never bless a
// good image, and would silently revert it — the original bug, wearing a
// different hat, aimed at the node classes least able to complain.
//
// So this asks the narrower, honest question. Absence of evidence is not proof
// the composition is sound, and it is not claimed to be: a node whose reconcile
// never reached the compose stage passes here and is gated on systemd alone,
// which is what it was before this conjunct existed. What it does buy is that
// an observed attach or union-mount failure now BLOCKS the bless instead of
// being logged while the image is promoted.
func (r *Reconciler) ComposedOK() bool {
	return !r.composeFailed.Load()
}
