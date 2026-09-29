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
	"github.com/nodealchemy/powernode-system/agent/internal/systemd"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// pivotAwareRootMode indirects lifecycle.PivotAwareRootMode so tests in
// this package can force the native-root (pivot node) gate without
// touching lifecycle's own root probe, which is unexported and keyed off
// the live process's actual "/" filesystem type — not fakeable from
// outside that package. Mirrors the same var-indirection pattern
// lifecycle/service.go itself uses internally (rootFSType).
var pivotAwareRootMode = lifecycle.PivotAwareRootMode

// pivotAwareRootModeChecked indirects lifecycle.PivotAwareRootModeChecked,
// same reason and same pattern as pivotAwareRootMode above. Kept as a
// SEPARATE var (not folded into pivotAwareRootMode's signature) because
// every existing caller of the unchecked form deliberately wants the
// swallow-to-chroot default — only the union-mount step below needs the
// error (IMP-81aa3112).
var pivotAwareRootModeChecked = lifecycle.PivotAwareRootModeChecked

// applyIdentity, applySudoers and reconcileHomeOwnership indirect
// etcidentity.Apply / etcsudoers.Apply / etcidentity.ReconcileHomeOwnership
// so tests can observe (or stub) the host-global render without touching
// real /etc or /home — same var-indirection pattern as pivotAwareRootMode
// above. TestMain (main_test.go) defaults all three to no-ops so a test that
// forgets to override them cannot touch the host even when run as root
// (review finding N5).
var applyIdentity = etcidentity.Apply
var applySudoers = etcsudoers.Apply
var reconcileHomeOwnership = etcidentity.ReconcileHomeOwnership

// applyHostname and applyBreakGlass are the same indirection for the two
// remaining live-root writers: the hostname reassert (/etc/hostname, the
// networkd drop-in, sethostname(2)) that reconcile.go and service.go reach via
// desiredHostname(), and the operator break-glass drop-in under
// /etc/sudoers.d that Service.Run applies (or REMOVES, when the env flag is
// off) before bootstrap. TestMain redirects both into its sandbox.
var applyHostname = etcidentity.ApplyHostname
var applyBreakGlass = etcsudoers.ApplyOperatorBreakGlass

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
	// Fsverity checks the blob's fs-verity Merkle-tree root against the
	// manifest's. nil skips the check (the DEFAULT); production sites take it
	// from ResolveModuleFsverity.
	Fsverity verify.DigestVerifier
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
	// AgentVersion is mixed into the re-attach stamp (see attachStamp). Empty
	// is allowed and simply contributes nothing — the rendered-output half of
	// the stamp still does the work.
	AgentVersion string

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
	// ExtraEgress, when set, supplies additional node-wide egress allowances
	// beyond any module's own declared policy — currently SDWAN's
	// wg-sdwan-* interfaces and peer dial targets, wired in service.go to
	// sdwan.Manager.EgressContributions (IMP-13645c4df90a: the default-deny
	// egress chain was dropping the WireGuard handshake outright). nil is
	// "no extras" — the pre-fix behavior, and what every non-SDWAN caller
	// (tests, NewReconcilerForCLI) gets by leaving this field zero. This
	// package deliberately does not import internal/sdwan for this — see
	// security.EgressExtras' own doc for why the seam is a func value
	// instead.
	ExtraEgress func() security.EgressExtras
	// SkipEgress, when true, makes RunOnce never touch the node-wide nft
	// egress chain at all (neither ApplyEgressAllowlistWithExtras nor
	// RemoveEgressAllowlist) — identity/sudoers still render normally.
	// IMP-13645c4df90a review round: the long-running SERVICE process is the
	// only one with live ExtraEgress data (SDWAN), and egress apply is now
	// an ATOMIC full-chain rebuild (one `nft -f`, replacing the WHOLE
	// chain) — a one-shot CLI reconciler (`update`/`sync`/`attach`/`detach`,
	// see NewReconcilerForCLI) calling RunOnce with no ExtraEgress would
	// rebuild the shared chain WITHOUT the service's SDWAN sport/oifname
	// rules, silently dropping the WireGuard tunnel until the service's own
	// next tick repairs it — and the two processes racing to rewrite the
	// same staged script path is a second hazard on top of that (see
	// applyEgressScript's own doc on the per-process staging filename this
	// pairs with). The CLI choosing "skip entirely" rather than "carry
	// forward the last-known extras" is deliberate: a CLI invocation has no
	// current SDWAN state to be right about, and a stale/guessed extras set
	// would be worse than leaving the service's own chain untouched.
	// NewReconcilerForCLI sets this true; every long-running service
	// reconciler leaves it false (the zero value).
	SkipEgress bool
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
	// UpgradeSettleWindow (M6, review round 9) is how long upgradeModule
	// waits after step 4 (write units + force-restart) before checking that
	// every unit the new manifest declares is still `active` — a
	// Type=simple unit's `systemctl start`/`restart` succeeding proves only
	// that ExecStart was launched, never that the process stayed up; a
	// binary that crashes immediately after exec (a bad migration, a config
	// the new digest ships that the process rejects on boot) would
	// otherwise sail through step 4 as a reported success. Zero means "no
	// WAIT" (sleepForUpgradeSettle(0) returns immediately) — the CHECK
	// itself always still runs regardless of the window's value, which is
	// what lets a test simulate "the unit was already dead by the time we
	// looked" via the runner's stubbed is-active response without a real
	// sleep. upgradeTestReconciler/versionBumpReconciler explicitly zero
	// this, since a real multi-second sleep in dozens of fast unit tests
	// would be its own defect. Left at its Go zero value here (not
	// defaulted in this struct); NewReconciler applies
	// DefaultUpgradeSettleWindow when unset, exactly like
	// ManifestTTL/ScratchMinFreeBytes above.
	UpgradeSettleWindow time.Duration
}

// DefaultUpgradeSettleWindow is the production default for
// UpgradeSettleWindow: long enough for an immediately-crashing Type=simple
// process to have already exited by the time upgradeModule checks, short
// enough not to meaningfully delay a healthy upgrade's commit.
const DefaultUpgradeSettleWindow = 3 * time.Second

// sleepForUpgradeSettle is upgradeModule's settle-window wait, indirected
// (like pivotAwareRootMode above) so a test can swap in a fake clock rather
// than actually blocking — though in practice every test using this package
// sets UpgradeSettleWindow to 0, which makes even the real time.Sleep return
// immediately, so this indirection exists for a future test that wants to
// assert something about the window's DURATION specifically without a real
// wait either way.
var sleepForUpgradeSettle = time.Sleep

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

	// securityFailClosedUnits is the LIVE set of units this reconciler
	// currently REFUSES to (re)attach/start on the cloud-init/pivot-reconcile
	// path because a non-exempt security drop-in write failed (attachModule,
	// IMP-caef5c00d63f phase 4 — operator decision: fail closed identically
	// on the boot AND the runtime path). A named unit is not necessarily
	// STOPPED — round 5 (G1) removed stopping an already-running unit on this
	// path as unrecoverable on a self-hosted node; a re-attach refusal leaves
	// it running under whatever confinement it already had. Read by
	// buildHeartbeat (HeartbeatPayload.RuntimeSecurityFailClosedUnits).
	//
	// ATOMIC, not guarded by mu, for the exact reason composeFailed is:
	// buildHeartbeat reads it from a different goroutine, and mu is held
	// across the entire RunOnce body.
	//
	// PUBLISHED EXACTLY ONCE PER PASS (review round 5, G4), not reset at the
	// top and accumulated in place: attachModule is called throughout the
	// attach/reattach loops, which take real wall-clock time (network
	// fetches, blob pulls, mount, systemctl), and a heartbeat racing a
	// mid-flight pass must never observe the RESET (empty) value a
	// zero-then-fill approach would expose between the reset and the first
	// failure being recorded — that would read as "recovered" to
	// SecurityFailClosedSensor and clear a real, still-open alarm, then
	// re-raise it once the pass finishes. securityFailClosedPending
	// accumulates the units THIS pass has found so far in an ordinary
	// (non-atomic) field — safe because every attachModule caller (RunOnce's
	// two loops, and AttachOne, which never publishes — see
	// SecurityFailClosedError and J2, review round 5) holds r.mu for its
	// ENTIRE body, so only one of them ever touches it at a time — and
	// publishSecurityFailClosed swaps the atomic pointer over to it in ONE
	// Store call once RunOnce's own pass finishes, so a concurrent reader
	// only ever sees the previous pass's complete result or this pass's
	// complete result, never a value from mid-pass.
	//
	// securityPolicyAttemptedUnits (J3, review round 5 REPLACEMENT review)
	// tracks which units this pass actually RAN the security-policy decision
	// for (applyModuleSecurityPolicy records into it unconditionally at
	// entry) — publishSecurityFailClosed is a FULL REPLACE keyed on pending
	// alone, so a module this pass could not even REACH the decision for
	// (a manifest fetch failure, a no-digest module, or a blob pull failure
	// ahead of the security step) would otherwise silently drop out of a
	// PREVIOUSLY published refusal, reading as "recovered" to
	// SecurityFailClosedSensor for a module whose confinement status this
	// pass never actually learned anything new about. Same lifecycle as
	// securityFailClosedPending: reset alongside it, read alongside it in
	// publishSecurityFailClosed, never itself published.
	securityFailClosedUnits      atomic.Pointer[[]string]
	securityFailClosedPending    []string
	securityPolicyAttemptedUnits []string

	// tickIdentityManifests (T1, final review on f3339424, HIGH) is THIS
	// tick's own full identity/sudoers manifest set — every currently
	// desired/attached module's manifest, with any actively-bumping
	// module's own contribution already substituted to old ∪ touched by
	// RunOnce's own render (see that render block's own doc) — set once per
	// RunOnce pass, immediately after that render computes it, and read by
	// every upgradeModule call the SAME tick.
	//
	// Before this field existed, upgradeModule's own pre-step-4 render
	// passed applyIdentityAndSudoers ONLY the bumping module's own old ∪
	// touched ∪ new manifests — a SUBSET of the node's real identity set.
	// etcidentity.Apply (and etcsudoers.Apply) render a FULL replacement set
	// from whatever manifests they are given, not a merge against what's
	// already on disk, so that subset silently wiped every OTHER module's
	// users/groups and sudoers grants for the rest of the tick — a second
	// module's own restart landing in that window got 217/USER for a user
	// upgradeModule never even knew existed. Set to nil + skipped=true
	// whenever RunOnce's own render is skipped entirely (an unresolved
	// attached module's manifest — same mustSkipRender gate as
	// reconciler:identity_render_skipped) — see tickIdentityRenderSkipped.
	tickIdentityManifests []*manifest.Manifest
	// tickIdentityRenderSkipped is true exactly when RunOnce's own render
	// this tick could not resolve every attached/boot-composed module's
	// manifest (mustSkipRender) — tickIdentityManifests is nil in that case,
	// and upgradeModule must refuse before step 4 rather than render
	// whatever partial set it does have: a partial render is exactly the
	// same "confidently wrong" failure mode mustSkipRender itself exists to
	// avoid, just reached through the bump path instead of RunOnce's own.
	tickIdentityRenderSkipped bool

	// securityFailClosedRecovered names units whose LIVE (attachModule)
	// security drop-in write has SUCCEEDED at least once since this boot —
	// proof this boot CAN write that unit's confinement correctly, regardless
	// of what a boot-time (pivot) compose attempt saw (review round 5, G5).
	// buildHeartbeat subtracts this set from the boot breadcrumb's
	// PivotSecurityFailClosedUnits: without it, a unit refused once at boot
	// keeps SecurityFailClosedSensor alarming for the ENTIRE uptime, even
	// after the live path proves the confinement now applies — the
	// breadcrumb is a one-time boot fact re-read unchanged on every
	// heartbeat, and nothing else ever revisits it.
	//
	// MONOTONIC for the life of the boot (only ever grows, never reset by
	// resetSecurityFailClosed) — a LATER live failure for the SAME unit is
	// still fully and separately visible via RuntimeSecurityFailClosedUnits,
	// so this suppression can never hide an ONGOING problem, only a stale
	// boot-time one. Merge-on-write directly into the atomic (unlike
	// securityFailClosedUnits, this field has no reset step to race with, so
	// it needs no separate pending/publish split).
	securityFailClosedRecovered atomic.Pointer[map[string]bool]

	// Latched result of the self-host probe (see selfhost.go). Guarded
	// separately from mu because selfHosted() is called from inside a
	// RunOnce that already holds mu.
	selfHostMu      sync.Mutex
	selfHostLatched bool

	// hostsControlPlaneModule (round Z, Z2) is set ONCE per RunOnce pass —
	// see hostsControlPlaneModule's own doc (selfhost.go) and this pass'
	// own computation right after state loads — to whether any currently
	// attached module resolves (by name) to the pinned control-plane list,
	// fail-safe on an unresolved name. restartPermitted consults this
	// alongside selfHostState() so a restart requires POSITIVE local proof
	// on BOTH axes, not resolver-only evidence. Touched only from inside
	// RunOnce, which holds mu for its own body — no lock of its own.
	hostsControlPlaneModule bool

	// confinementStaleUnits (round Y, IMP-caef5c00d63f — confinement_probe.go)
	// is the LAST PUBLISHED set of units whose running capabilities diverge
	// from their manifest's declared ceiling, mirroring securityFailClosedUnits'
	// own atomic-pointer publish pattern: one Store call at the end of each
	// reconcileStaleConfinement pass, read by ConfinementStaleUnits() (in
	// turn by buildHeartbeat) from any goroutine without a lock. Recomputed
	// from scratch every tick — nothing here is loaded from state.json on
	// startup, unlike securityFailClosedUnits' own boot-time seed, since a
	// fresh agent process has no need to CARRY FORWARD a stale-confinement
	// verdict: the next tick's own /proc probe re-derives it immediately.
	confinementStaleUnits atomic.Pointer[[]string]

	// Boot state rebase bookkeeping (see state_rebase.go), guarded by mu —
	// only RunOnce touches it. stateRebaseActive holds the condition ids the
	// last evaluation raised (a condition is signalled when it newly appears);
	// stateRebaseMemo is the composition key + fingerprint of the last verdict
	// that changed nothing, so an unchanged node is not re-probed every tick.
	stateRebaseActive map[string]bool
	stateRebaseMemo   string

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

// retainedAfterDetach returns the subset of attached NOT present in
// toDetach, matched by Digest — mount.Reconcile's own diff key, and the
// same key filterUnsafeDetaches and the later "filter out detached
// modules" block in RunOnce already use. Two versions of the same module
// ID never share a digest, so this is exactly "what mount.Reconcile (as
// filtered by every detach guard) decided must actually go" applied back
// against the PRIOR attached list.
//
// This is the authoritative "what is actually staying attached this tick"
// set (IMP-2dfbd7f62441 review finding B1). It is DELIBERATELY not the same
// thing as `desired`: `desired` is only the modules this tick could fetch a
// FRESH manifest for, and a module can stay attached without ever entering
// that set — e.g. filterUnsafeDetaches's self-host refusal, or simply
// because the assigned-modules list itself omitted it this tick (a
// degraded-but-200 response; FetchAssignedModules erroring outright already
// aborts RunOnce before this point and touches nothing). Every render and
// hot-prune decision that asks "what modules are really here" must use
// this, not `desired` — using `desired` is how a retained-but-unlisted
// module's declared users silently disappear from /etc/passwd while the
// module keeps running.
func retainedAfterDetach(attached, toDetach mount.ModuleStack) mount.ModuleStack {
	if len(toDetach) == 0 {
		return attached
	}
	detachedDigests := make(map[string]bool, len(toDetach))
	for _, m := range toDetach {
		detachedDigests[m.Digest] = true
	}
	out := make(mount.ModuleStack, 0, len(attached))
	for _, m := range attached {
		if !detachedDigests[m.Digest] {
			out = append(out, m)
		}
	}
	return out
}

// loadBreadcrumbManifests returns the manifest embedded in each boot-composed
// breadcrumb entry (LKGModule.Manifest — exactly what ComposeForPivot
// rendered identity from at boot, see compose.go's identity render), the full
// set of module IDs the breadcrumb lists, and the subset of those IDs that
// are data-bearing (HasDataFile — the same gate the live manifest-fetch loop
// applies; a config/skill module never enters identity/sudoers resolution
// either way, so it must not become a "candidate" via the breadcrumb path).
// The plain ID set is deliberately wider than the manifest map: a breadcrumb
// entry without HasDataFile, or one whose embedded manifest bytes are
// empty/unparseable, still names a module this boot genuinely composed
// (IMP-2dfbd7f62441 review finding R2-B1) — callers use the ID set to tell
// "this module IS real, we just can't recover its manifest" from "this
// module was never part of anything".
//
// REFUSES a breadcrumb from a DIFFERENT boot (review finding round-4 #2,
// same rationale as lkg_capture.go's own promotion guard, which this
// mirrors exactly): the breadcrumb write is best-effort, so a failed write
// on THIS boot leaves the PREVIOUS boot's file on disk — that stale file
// describes a composition this boot did not necessarily still have running
// (a module could have been detached, or never even pulled, in the
// meantime), so trusting it as "real" would manufacture false positives.
// Empty on either side (bc.BootID or CurrentBootID()) means the id is
// unavailable (non-Linux, /proc absent pre-mount) — proceeding without
// verification there is deliberate, matching lkg_capture.go, rather than
// silently disabling this fallback in every sandboxed test and non-Linux
// build.
//
// Best-effort throughout: absent, unreadable, or stale all return empty
// maps, never an error the caller must handle (mirrors stagePendingCompose's
// own LoadBreadcrumb use).
func loadBreadcrumbManifests() (manifests map[string]*manifest.Manifest, ids map[string]bool, dataIDs map[string]bool) {
	manifests = map[string]*manifest.Manifest{}
	ids = map[string]bool{}
	dataIDs = map[string]bool{}
	bc, err := LoadBreadcrumb(BootBreadcrumbPath)
	if err != nil || bc == nil {
		return manifests, ids, dataIDs
	}
	nowBoot := currentBootID()
	if nowBoot != "" && bc.BootID != "" && bc.BootID != nowBoot {
		return manifests, ids, dataIDs
	}
	return breadcrumbManifestSets(bc)
}

// breadcrumbManifestSets decodes a breadcrumb the caller has already vetted
// into loadBreadcrumbManifests' three sets.
func breadcrumbManifestSets(bc *BootComposedBreadcrumb) (manifests map[string]*manifest.Manifest, ids map[string]bool, dataIDs map[string]bool) {
	manifests = map[string]*manifest.Manifest{}
	ids = map[string]bool{}
	dataIDs = map[string]bool{}
	for _, lm := range bc.Modules {
		ids[lm.ID] = true
		if lm.HasDataFile {
			dataIDs[lm.ID] = true
		}
		if len(lm.Manifest) == 0 {
			continue
		}
		var m manifest.Manifest
		if uerr := json.Unmarshal(lm.Manifest, &m); uerr == nil {
			manifests[lm.ID] = &m
		}
	}
	return manifests, ids, dataIDs
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
	if cfg.UpgradeSettleWindow == 0 {
		cfg.UpgradeSettleWindow = DefaultUpgradeSettleWindow
	}
	if cfg.OnError == nil {
		cfg.OnError = func(string, error) {}
	}
	r := &Reconciler{cfg: cfg}
	// R6 (review round 14): seed the published fail-closed set from
	// state.json's own last-persisted copy (mount.State.SecurityFailClosedUnits,
	// written by publishSecurityFailClosed) — without this, a fresh process
	// (a real agent restart, or simply this process exiting and a new one
	// starting) reports a CLEAN node on its very first heartbeat, until the
	// first RunOnce pass re-decides every module — even for a module that
	// was refused, unconfined, right up until the restart. Best-effort: a
	// missing or unreadable state.json seeds nothing (mount.LoadState
	// itself returns a zero-value State, not an error, for a missing file)
	// rather than failing construction over a purely advisory seed.
	if st, err := mount.LoadState(cfg.StatePath); err == nil && len(st.SecurityFailClosedUnits) > 0 {
		seeded := append([]string(nil), st.SecurityFailClosedUnits...)
		r.securityFailClosedUnits.Store(&seeded)
	}
	return r, nil
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
	// Reset before ANYTHING in this pass can record a fail-closed refusal —
	// kept at the very top of RunOnce rather than just above the attach
	// loop so a future recorder (this pass had one during round 6/7's
	// detach-before-attach mitigation, since removed — round 9) can never
	// land between a later reset point and its own recording call.
	r.resetSecurityFailClosed()

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

	// Snapshot whatever manifest is CURRENTLY cached on disk for every
	// assigned module, BEFORE the fetch loop below overwrites that cache
	// with this tick's fresh content. manifest.LoadOrFetch keys its on-disk
	// cache by module ID alone (not by digest), so a module's OLD manifest
	// is otherwise unrecoverable the moment a new one is fetched. Used as a
	// fallback source for K4's relevantUnits bound (below) when a module's
	// fetch fails THIS tick and there is no fresher manifest to consult. A
	// module with no cache yet (never attached, or its cache write
	// previously failed) simply has no entry here.
	previousManifests := make(map[string]*manifest.Manifest, len(desiredModules))
	for _, mod := range desiredModules {
		if pm, perr := manifest.LoadFromDisk(r.cfg.ManifestRoot, mod.ID); perr == nil && pm != nil {
			previousManifests[mod.ID] = pm
		}
	}

	// Build desired ModuleStack by fetching manifests for modules with data files.
	desired := make(mount.ModuleStack, 0, len(desiredModules))
	manifests := make(map[string]*manifest.Manifest, len(desiredModules))
	// manifestFetchFailed records every assigned, data-bearing module whose
	// manifest.LoadOrFetch call errored THIS tick (a transient failure — e.g.
	// the platform 502ing mid-restart, IMP-2dfbd7f62441 / the 2026-09-22
	// ops-hub outage) — as opposed to a module that is simply not assigned at
	// all, which never reaches this loop. Deliberately NOT set for the
	// no-digest case just below: that manifest loaded, but it is a half-
	// published view, so it must not feed the render's cache fallback (a
	// never-attached digestless module would render its users). That case is
	// tracked in noDigest instead, which feeds ONLY the detach deferral.
	//
	// Consumed in two places below: filterUnverifiedDetaches (defers this
	// module's detach rather than reading the fetch failure as a real
	// unassignment), and — unioned with `retained` into `candidateIDs`
	// (review finding R2-B1) — the manifest-resolution loop that decides what
	// the identity/sudoers/egress render and the hot-prune layer stack see.
	// The union matters: a module can be in manifestFetchFailed but NOT
	// retained (its fetch failed on a tick where state.json itself is empty
	// — e.g. a reprovisioned /persist — so `retained` has nothing to say
	// about it at all), and resolving it needs the SAME cache/breadcrumb
	// fallback treatment a retained module gets.
	manifestFetchFailed := map[string]bool{}
	// noDigest records every assigned, data-bearing module whose manifest
	// loaded with no digest (IMP-1023e79cc82d). Its absence from `desired` is
	// not a removal, so its detach is deferred exactly like a fetch failure's,
	// but nothing else reads it.
	noDigest := map[string]bool{}
	for _, mod := range desiredModules {
		if !mod.HasDataFile {
			continue // config-variety + skill modules have no blob to mount
		}
		m, err := manifest.LoadOrFetch(r.cfg.ManifestClient, r.cfg.ManifestRoot, mod.ID, r.cfg.ManifestTTL)
		if err != nil {
			if m == nil {
				r.noteUnconverged("reconciler:fetch_manifest", mod.ID, fmt.Errorf("module %s: %w", mod.ID, err))
				manifestFetchFailed[mod.ID] = true
				continue
			}
			// FetchAndCache (manifest/loader.go) returns a VALID manifest
			// alongside a non-nil error when only the on-disk cache WRITE
			// failed — the platform fetch itself succeeded, so this tick's
			// in-memory view of the module is current. Treating this as a
			// fetch failure (dropping `m`) would manufacture a partial view
			// out of a write-side problem that has nothing to do with
			// whether we know the module's real state. Log and use `m`
			// normally; the next tick's cache read simply refetches.
			r.cfg.OnError("reconciler:manifest_cache_write_failed", fmt.Errorf("module %s: %w", mod.ID, err))
		}
		if m.Digest == "" {
			// A live assignment can arrive with no digest, not only a module
			// that was "never published": NodeModuleVersion#artifact picks
			// specifically the "erofs" key out of #artifacts, while the
			// serializer's `has_data_file` (the gate that puts a module into
			// this loop at all) checks `#artifacts.present?` — ANY published
			// format. So a module published only in a non-erofs format (e.g.
			// mid composefs-format migration, or a publish that wrote the
			// wrong key) is has_data_file=true with digest=="" here.
			//
			// It is therefore recorded in noDigest: the platform did not say
			// which build this module is, so its absence from `desired` must
			// never be read as an unassignment. Without this, mount.Reconcile
			// saw it as absent from desired and present in current, and on a
			// node that is not self-hosted (where filterUnsafeDetaches does not
			// apply) the module — with its declared users — was detached this
			// tick (IMP-1023e79cc82d). filterUnverifiedDetaches defers that
			// detach. It is NOT put in manifestFetchFailed: that set feeds the
			// render's cache fallback, which would render a never-attached
			// module's users from the digestless cache written this tick.
			noDigest[mod.ID] = true
			r.noteUnconverged("reconciler:no_digest", mod.ID, fmt.Errorf("module %s has no digest (not published)", mod.ID))
			continue
		}
		desired = append(desired, mount.Module{
			ID:              mod.ID,
			Digest:          m.Digest,
			Priority:        m.EffectivePriority,
			FsverityRoot:    m.FsverityRootHash,
			CosignBundleB64: m.CosignBundleB64,
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

	// Captured BEFORE the state rebase below and before anything else mutates
	// current.AttachedModules. ComposeForPivot doesn't persist a state.json at
	// boot, so on the very first reconcile tick of a node, current is empty
	// and every boot module shows up in toAttach even though its files are
	// ALREADY part of the boot union — hotReconcileIfNeeded must not copy on
	// that baseline tick (see its doc comment). Later ticks have real prior
	// state (RunOnce SaveState's at the end of every cycle), so stateWasEmpty
	// reflects "is this a genuine post-boot change".
	//
	// Not re-measured after the rebase: a rebase that empties a non-empty state
	// is not that baseline. The skip is silent (no unmaterialized record, units
	// still start), so treating it as baseline would leave a newly assigned
	// module the boot did not compose running against files never copied onto
	// /. Measured here, the rebase leaves the hot-copy decision exactly as it
	// was before the rebase existed.
	stateWasEmpty := len(current.AttachedModules) == 0

	// Drop entries for modules this boot did not compose and that nothing
	// shows live (see state_rebase.go). Report-only unless explicitly enabled.
	assignedIDs := make(map[string]bool, len(desiredModules))
	for _, mod := range desiredModules {
		assignedIDs[mod.ID] = true
	}
	r.rebaseStateAgainstBoot(ctx, current, stateRebaseInputs{fresh: manifests, fetchFailed: manifestFetchFailed, assigned: assignedIDs})

	// Round Z (Z2, widened Z5): compute THIS tick's own positive-proof
	// signal for restartPermitted (selfhost.go) — after the rebase has
	// settled current.AttachedModules, before any attach/reattach loop can
	// restart anything. Z5 (reviewer A, MEDIUM): scanning
	// current.AttachedModules ALONE missed a hub module on its own first
	// pivot boot (state empty, nothing "attached" yet by this tick's own
	// bookkeeping) or right after a state rebase drops its entries — the
	// gate read as clear, and the fresh-attach loop's own R1 restarted a
	// unit compose had already started. Scanning the UNION of attached AND
	// desired/assigned modules closes that: a hub module about to be
	// attached this same tick counts just as much as one already running.
	// See hostsControlPlaneModule's own doc for the fail-safe (a module
	// whose manifest this tick could not resolve, or whose Name is empty,
	// counts AS control-plane).
	r.hostsControlPlaneModule = hostsControlPlaneModule(unionModulesByID(current.AttachedModules, desired), manifests)

	// O7 (review round 12): bootstrap the N3 attached-snapshot store for any
	// module whose CURRENTLY attached digest has no snapshot of its own yet —
	// a node that attached before N3 (round 11) existed, or one that has not
	// gone through a fresh attach/reattach tick since. Without this, the
	// FIRST upgrade attempt against such a module falls through to
	// previousManifests (the ID-keyed "latest fetch" cache) for "what was the
	// old digest's content", which is fine for that one attempt — but a
	// SECOND attempt (a retry, or a revert) runs AFTER this tick's fetch loop
	// above has already overwritten previousManifests' own on-disk source
	// with the ATTEMPTED (new) digest's content, so the second attempt would
	// silently read the new digest back as "the old one". That is exactly
	// the second-failed-tick bug N3 exists to prevent; this closes the one
	// gap where it can still happen — the window before a node's first
	// attach/reattach since N3 shipped. Uses previousManifests as captured
	// BEFORE this tick's own fetch loop, per its own doc comment above. The
	// digest must match exactly what mount.Module actually has attached
	// right now — a stale or unrelated cache entry describes different
	// content and must never be mistaken for the running digest's own. Run
	// after rebaseStateAgainstBoot so a module the boot dropped is never
	// bootstrapped or GC'd for nothing.
	for _, mod := range current.AttachedModules {
		if mod.Digest == "" {
			continue
		}
		if _, aerr := manifest.LoadAttachedSnapshot(r.cfg.ManifestRoot, mod.ID, mod.Digest); aerr == nil {
			continue // already bootstrapped (or genuinely attached/reattached under N3)
		}
		pm, ok := previousManifests[mod.ID]
		if !ok || pm == nil || pm.Digest != mod.Digest {
			continue // no cached content matching the currently-attached digest
		}
		// P6 (review round 13, LOW): the digest match above is not enough
		// on its own. previousManifests is the ID-keyed "latest fetch"
		// cache — a manifest-only edit (same digest, changed services:/
		// capabilities/etc.) that FETCHED successfully but was then
		// REFUSED at reattach (a hot-reconcile or policy refusal) leaves
		// this cache holding the NEW, never-successfully-applied content,
		// while the actually-attached content on disk is still the OLD
		// version — current.LastAttachedManifestHashes[mod.ID] was never
		// updated to the new stamp precisely because the reattach failed.
		// Comparing the cached manifest's OWN stamp against that
		// last-successful one closes the gap: only a cached manifest that
		// genuinely matches what was last successfully applied is trusted
		// as "what's actually attached right now".
		//
		// Q2 (review round 14, MEDIUM): compare CONTENT only
		// (attachStampContent / stampContentOnly), never the full,
		// version-qualified attachStamp — the full stamp ends in
		// "|"+AgentVersion, so on the first tick after an agent binary
		// upgrade EVERY stored LastAttachedManifestHashes entry (computed
		// under the OLD version) would disagree with a freshly computed one
		// even when the manifest's own content is byte-identical, wrongly
		// treating an unrelated agent upgrade as "this isn't really what's
		// attached" — and once the next tick's fetch overwrites the ID-keyed
		// cache with the new manifest, the miss becomes permanent.
		if r.attachStampContent(mod.ID, pm) != stampContentOnly(current.LastAttachedManifestHashes[mod.ID]) {
			continue // cached content is a refused edit, not what's actually attached
		}
		if serr := manifest.SaveAttachedSnapshot(r.cfg.ManifestRoot, mod.ID, mod.Digest, pm); serr != nil {
			r.cfg.OnError("reconciler:upgrade_snapshot_bootstrap", fmt.Errorf("module %s digest %s: %w", mod.ID, mod.Digest, serr))
		}
	}
	// O7 (review round 12): GC the N3 store — every module still attached
	// keeps only its currently-attached digest and its PendingDigest (if
	// mid-upgrade); everything else is a resolved past attempt with no
	// remaining reader. A module leaving the composition entirely is
	// cleaned up in detachModule instead, once it actually detaches.
	// Q1 (review round 14): ALSO keep every digest in PendingTouchedDigests —
	// the identity/sudoers/egress render unions each touched digest's own
	// snapshot back in for as long as the episode stays open, so GC'ing one
	// out from under it would silently narrow that render mid-episode.
	for _, mod := range current.AttachedModules {
		keep := append([]string{mod.Digest, mod.PendingDigest}, mod.PendingTouchedDigests...)
		if perr := manifest.PruneAttachedSnapshots(r.cfg.ManifestRoot, mod.ID, keep...); perr != nil {
			r.cfg.OnError("reconciler:upgrade_snapshot_gc", fmt.Errorf("module %s: %w", mod.ID, perr))
		}
	}

	toAttach, toDetach := mount.Reconcile(current, desired)

	// Partition version bumps OUT of toDetach/toAttach entirely (round 9,
	// in-place-upgrade redesign). mount.Reconcile compares by DIGEST, so a
	// same-module-ID change (a bump) shows up as an OLD entry in toDetach
	// and a NEW entry in toAttach — under detach-before-attach (rounds
	// 5-7, removed) those flowed through the ordinary detach/attach loops,
	// which is exactly the outage shape that stack existed to mitigate. As
	// of round 9, a bump never enters either loop: it is handled entirely
	// by upgradeModule, which — per the round-11 redefined invariant, see
	// upgradeModule's own doc — MAY restart the old digest's units as part
	// of a genuine version upgrade (that's the only way a bump ever takes
	// effect), but never as a side effect of a refusal or bookkeeping path.
	// A module with no same-ID entry on the other side is a genuine removal
	// or a genuine fresh attach and is untouched by this partition.
	newByID := make(map[string]mount.Module, len(toAttach))
	for _, m := range toAttach {
		newByID[m.ID] = m
	}
	// M4 fix (b) (review round 9, MEDIUM, hard invariant): a DUPLICATE
	// state.json entry for one module ID at two different digests (the
	// pre-fix AttachOne bug — fix (a), below — or any future source of the
	// same shape) makes mount.Reconcile's have/want-by-digest diff treat
	// the STALE digest as toDetach with NOTHING in toAttach for the same ID
	// (the OTHER entry already satisfies `desired`, so toAttach has nothing
	// to add) — which the bump partition above cannot recognize as a bump
	// (newByID has no entry for it) and would otherwise route straight into
	// `removals`, stopping units a DIFFERENT, still-live entry for the SAME
	// ID is currently serving. desiredIDs catches this: any toDetach
	// candidate whose ID is STILL in `desired` at all (not just matched by
	// digest) is a stale duplicate, never a genuine removal — drop the
	// specific stale (ID, digest) entry from state directly, WITHOUT
	// touching any unit.
	desiredIDs := make(map[string]bool, len(desired))
	for _, m := range desired {
		desiredIDs[m.ID] = true
	}
	var bumps []moduleUpgrade
	// N9 (review round 11): dedupe bumps by ID — a duplicate toDetach entry
	// for the SAME module ID (any future source of the M4 duplicate-state
	// shape this partition doesn't already special-case above) must never
	// produce two moduleUpgrade entries for one ID, which would run
	// upgradeModule TWICE in the same tick for the same module: the second
	// run's own step 1 (mountModuleArtifact) is idempotent, but its step 4
	// force-restart is NOT idempotent-free of side effects (a second
	// `restart` mid-settle-window of the first run's own attempt), and its
	// step 7 would try to replace an entry the first run's own step 7
	// already replaced.
	bumpedIDs := make(map[string]bool, len(toDetach))
	removals := make(mount.ModuleStack, 0, len(toDetach))
	for _, m := range toDetach {
		if newMod, isBump := newByID[m.ID]; isBump {
			if bumpedIDs[m.ID] {
				r.cfg.OnError("reconciler:duplicate_bump_dropped", fmt.Errorf(
					"module %s: a second toDetach entry at digest %s named the same upgrade target — dropping the duplicate, not running upgradeModule twice in one tick", m.ID, m.Digest))
				continue
			}
			bumpedIDs[m.ID] = true
			bumps = append(bumps, moduleUpgrade{old: m, new: newMod})
			continue
		}
		if desiredIDs[m.ID] {
			for i, am := range current.AttachedModules {
				if am.ID == m.ID && am.Digest == m.Digest {
					current.AttachedModules = append(current.AttachedModules[:i], current.AttachedModules[i+1:]...)
					r.cfg.OnError("reconciler:drop_duplicate_state_entry", fmt.Errorf(
						"module %s: dropping a stale state entry at digest %s — the module is still desired and already satisfied by a different attached digest; its units are NOT being stopped", m.ID, m.Digest))
					break
				}
			}
			continue
		}
		removals = append(removals, m)
	}
	toDetach = removals
	if len(bumps) > 0 {
		bumpIDs := make(map[string]bool, len(bumps))
		for _, b := range bumps {
			bumpIDs[b.new.ID] = true
		}
		filteredAttach := make(mount.ModuleStack, 0, len(toAttach))
		for _, m := range toAttach {
			if !bumpIDs[m.ID] {
				filteredAttach = append(filteredAttach, m)
			}
		}
		toAttach = filteredAttach
	}

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
	bumpIDsThisTick := make(map[string]bool, len(bumps))
	for _, b := range bumps {
		bumpIDsThisTick[b.new.ID] = true
	}
	// N2 (review round 11): an entry left with a PendingDigest from a
	// failed/incomplete upgrade attempt, whose desired digest has since
	// REVERTED back to this entry's own stable Digest, looks like NOTHING
	// happened by either measure this function otherwise uses — Digest
	// itself never changed (mount.Reconcile's own diff sees no bump) and
	// the manifest content at that stable digest hasn't changed either (the
	// stamp below still matches). Both would silently leave whatever the
	// failed attempt broke (a crashed or half-restarted unit) exactly as it
	// was, forever, since nothing else in this tick will ever touch this
	// module again. Any entry reaching this reattach loop at all already
	// has mod.Digest == its own current stable Digest (the digest-diff
	// bump partition above claims every OTHER case), so a nonzero
	// PendingDigest here can only mean a revert-to-stable, never a
	// still-in-flight retry (a retry's target differs from the stable
	// digest, so mount.Reconcile already routed it into `bumps`).
	pendingRevertIDs := make(map[string]bool, len(current.AttachedModules))
	pendingAttemptsByID := make(map[string]int, len(current.AttachedModules))
	pendingLastAttemptByID := make(map[string]int64, len(current.AttachedModules))
	revertAttemptsResetThisTick := false
	for i, m := range current.AttachedModules {
		if m.PendingDigest == "" {
			continue
		}
		pendingRevertIDs[m.ID] = true
		// Q5 (review round 14, LOW): a module genuinely REVERTING this tick
		// (bumpIDsThisTick already excludes anything still actively
		// bumping) that has never had its counter reset FOR THIS REVERT
		// EPISODE carries PendingDigestAttempts accumulated by the
		// ABANDONED upgrade attempt's own step 1-3 refusals (P7) against a
		// DIFFERENT target (mod.PendingDigest, not the stable digest being
		// reverted to) — feeding that stale count into the revert's own
		// backoff gate would back off its very FIRST force-restart attempt
		// as though it were already deep into a crash loop. Reset ONCE per
		// episode (PendingRevertAttemptsReset), not on every revert-retry
		// tick — a revert that keeps failing on its OWN attempts must still
		// back off normally from there, exactly as O3 (review round 12)
		// intends.
		if !bumpIDsThisTick[m.ID] && !m.PendingRevertAttemptsReset {
			current.AttachedModules[i].PendingDigestAttempts = 0
			current.AttachedModules[i].PendingDigestLastAttemptUnix = 0
			current.AttachedModules[i].PendingRevertAttemptsReset = true
			revertAttemptsResetThisTick = true
			pendingAttemptsByID[m.ID] = 0
			pendingLastAttemptByID[m.ID] = 0
			continue
		}
		pendingAttemptsByID[m.ID] = m.PendingDigestAttempts
		pendingLastAttemptByID[m.ID] = m.PendingDigestLastAttemptUnix
	}
	if revertAttemptsResetThisTick {
		if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
			r.cfg.OnError("reconciler:revert_attempts_reset_save", fmt.Errorf("could not persist a revert episode's attempts reset: %w", err))
		}
	}
	// W2/X4 (IMP-caef5c00d63f): once-per-boot-composition drop-in
	// reverification no longer forces a module into THIS loop at all — see
	// reconfirmConfinementIfNeeded (confinement_recheck.go), called near the
	// end of this tick, for why a narrower, dedicated path replaced routing
	// it through the full ordinary reattach gate below.
	toReattach := make(mount.ModuleStack, 0)
	for _, mod := range desired {
		if !attachedNow[mod.ID] {
			continue // either freshly attaching (handled below) or not yet pulled
		}
		// round 9: a module this tick already partitioned into `bumps`
		// (above) is handled ENTIRELY by upgradeModule. Without this,
		// EVERY version bump also landed in toReattach — attachStamp always
		// differs across a digest change, so the stamp-diff check below
		// could never tell "manifest-only edit" from "this is also a
		// digest bump" apart — closing the exact bypass that let a
		// deferred bump's new digest still reach a real attachModule call
		// through this loop even when the (now-removed) detach-before-
		// attach deferral logic had decided to touch nothing at all
		// (round 7 finding, L2 part 1's own red-first test).
		if bumpIDsThisTick[mod.ID] {
			continue
		}
		mf, ok := manifests[mod.ID]
		if !ok {
			continue
		}
		fresh := r.attachStamp(mod.ID, mf)
		if pendingRevertIDs[mod.ID] || current.LastAttachedManifestHashes[mod.ID] != fresh {
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
	// loop below — that ordering is the entire point of this call (M8,
	// review round 9: prefetchNewArtifacts no longer returns a value at
	// all, so there is nothing left here to discard).
	r.prefetchNewArtifacts(ctx, toAttach)

	// Defer detaches for modules this tick could not get a manifest for at
	// all — see filterUnverifiedDetaches. Applied BEFORE filterUnsafeDetaches
	// (and unconditionally, not just on a self-hosted node): a fetch failure
	// means "we don't know", never "removed", so it must never be read as a
	// removal on ANY node, self-hosted or not.
	detachDeferred := make(map[string]bool, len(manifestFetchFailed)+len(noDigest))
	for id := range manifestFetchFailed {
		detachDeferred[id] = true
	}
	for id := range noDigest {
		detachDeferred[id] = true
	}
	toDetach = r.filterUnverifiedDetaches(toDetach, detachDeferred)
	toDetach = r.filterEmptyAssignmentDetaches(toDetach, desiredModules)

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
	//
	// round 9: captureOutgoingPaths only ever produces an entry for a
	// module ID present in BOTH its toDetach and toAttach arguments (its
	// own incoming[] check) — which, before this tick's bump partition
	// above, was exactly how it captured a version bump's outgoing paths.
	// Now that bumps never appear in toDetach/toAttach at all, that path
	// is called SEPARATELY here, against the bump pairs directly, and
	// merged into the same map upgradeModule's own hotReconcileIfNeeded
	// call (below) reads from.
	outgoingPaths := r.captureOutgoingPaths(toDetach, toAttach, manifests)
	if len(bumps) > 0 {
		bumpOld := make(mount.ModuleStack, 0, len(bumps))
		bumpNew := make(mount.ModuleStack, 0, len(bumps))
		for _, b := range bumps {
			bumpOld = append(bumpOld, b.old)
			bumpNew = append(bumpNew, b.new)
		}
		if bumpOutgoing := r.captureOutgoingPaths(bumpOld, bumpNew, manifests); len(bumpOutgoing) > 0 {
			if outgoingPaths == nil {
				outgoingPaths = make(map[string]map[string]bool, len(bumpOutgoing))
			}
			for id, paths := range bumpOutgoing {
				outgoingPaths[id] = paths
			}
		}
	}

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

	// retained is what mount.Reconcile (as filtered by every detach guard
	// above) decided is ACTUALLY still attached this tick — see
	// retainedAfterDetach. This, not `desired`, is the set the identity/
	// sudoers/egress render and the hot-prune layer resolution below must
	// agree with (IMP-2dfbd7f62441 review finding B1).
	retained := retainedAfterDetach(current.AttachedModules, toDetach)

	// The render's manifest set — see resolveRenderCandidates for how every
	// candidate is chosen and resolved (review findings R2-B1, round-4 #1, N2,
	// N3).
	breadcrumbManifests, breadcrumbIDs, breadcrumbDataIDs := loadBreadcrumbManifests()
	rc := r.resolveRenderCandidates(manifests, retained, manifestFetchFailed, breadcrumbManifests, breadcrumbIDs, breadcrumbDataIDs)
	mergedManifests := rc.merged
	desiredForLayers := make(mount.ModuleStack, len(desired), len(desired)+len(rc.retainedNotFresh))
	copy(desiredForLayers, desired)
	desiredForLayers = append(desiredForLayers, rc.retainedNotFresh...)
	staleFallback, breadcrumbFallback, unresolvedHarmless, unresolvedReal := rc.staleFallback, rc.breadcrumbFallback, rc.unresolvedHarmless, rc.unresolvedReal
	mustSkipRender := len(unresolvedReal) > 0

	if len(staleFallback) > 0 {
		sort.Strings(staleFallback)
		r.cfg.OnError("reconciler:identity_render_stale_manifest", fmt.Errorf(
			"this pass could not refresh %d module(s)' manifest(s) [%s]; rendering /etc/passwd + sudoers + egress from their last CACHED manifest instead of treating them as gone",
			len(staleFallback), strings.Join(staleFallback, ", ")))
	}
	if len(breadcrumbFallback) > 0 {
		sort.Strings(breadcrumbFallback)
		r.cfg.OnError("reconciler:identity_render_breadcrumb_manifest", fmt.Errorf(
			"this pass could not refresh or find a cache for %d module(s)' manifest(s) [%s]; rendering /etc/passwd + sudoers + egress from the boot breadcrumb's embedded manifest instead of treating them as gone",
			len(breadcrumbFallback), strings.Join(breadcrumbFallback, ", ")))
	}
	if len(unresolvedHarmless) > 0 {
		sort.Strings(unresolvedHarmless)
		r.cfg.OnError("reconciler:identity_render_unresolved", fmt.Errorf(
			"this pass has %d module(s) [%s] with no fresh, cached, or breadcrumb manifest; they are omitted from this tick's render (harmless — none of them was ever attached or boot-composed)",
			len(unresolvedHarmless), strings.Join(unresolvedHarmless, ", ")))
	}

	if mustSkipRender {
		sort.Strings(unresolvedReal)
		r.cfg.OnError("reconciler:identity_render_skipped", fmt.Errorf(
			"this pass could not resolve %d module(s) [%s] that ARE attached or boot-composed (no fresh manifest, no usable cache, no breadcrumb entry); skipping the /etc/passwd + sudoers + egress render entirely rather than render a view known to be missing a real module — the previous render stays in effect",
			len(unresolvedReal), strings.Join(unresolvedReal, ", ")))
		// T1: no full identity set exists this tick at all — any bump this
		// tick's own upgradeModule call must refuse its own pre-step-4
		// render rather than render a subset (see tickIdentityRenderSkipped's
		// own doc).
		r.tickIdentityManifests = nil
		r.tickIdentityRenderSkipped = true
	} else {
		mergedManifestsSlice := make([]*manifest.Manifest, 0, len(mergedManifests))
		for _, m := range mergedManifests {
			mergedManifestsSlice = append(mergedManifestsSlice, m)
		}

		// M3 (review round 9, HARD INVARIANT): mergedManifests already holds
		// THIS tick's fresh (NEW) manifest for a module being upgraded
		// (populated by the fetch loop above, unconditionally, regardless of
		// the bump partition) — but the OLD process is still the one
		// running until upgradeModule's step 7 actually commits. Rendering
		// identity/sudoers/egress from the new manifest alone describes a
		// process that isn't running yet: if the new manifest drops a user
		// the OLD unit's systemd definition still names via User=, that
		// unit's next crash-restart fails 217/USER — the 2026-09-22 outage
		// class, self-inflicted by the render instead of by an actual
		// detach. Until commit: identity/sudoers render the UNION of old
		// and new (etcidentity.Collect/etcsudoers.CollectFromManifests
		// already union by name across their WHOLE input slice, so simply
		// including old's manifest alongside new's IS the union — no
		// synthetic manifest type needed); egress keeps the OLD declaration
		// ONLY — a bump must not narrow or widen the enforced egress ahead
		// of the binary that will actually apply it. Both switch to the
		// new-only view automatically the tick AFTER a successful commit,
		// once the module is no longer in `bumps` at all (mount.Reconcile
		// then sees matching digests on both sides and stops pairing it).
		//
		// oldMf comes from previousManifests (RunOnce's own pre-fetch disk
		// snapshot, the same source upgradeModule's oldUnitNames fallback
		// uses) — a render-only advisory read, not the R3b security-content
		// restore path, so its own known limitation (stale past the first
		// attempt) only ever costs a one-tick delay in dropping an old-only
		// user or switching egress, not a confinement gap.
		identityManifests := mergedManifestsSlice
		egressManifestsSlice := mergedManifestsSlice
		// T2 (final review on f3339424, LOW): bumpOldSide is declared OUTSIDE
		// the `len(bumps) > 0` gate below so a tick with NO bump in flight at
		// all — a pure revert-to-stable, which never appears in `bumps` at
		// all (desired already resolves back to the attached digest, so
		// mount.Reconcile's own diff sees no bump to pair) — still reaches
		// the union loop further down that consults it (empty, in that
		// case) alongside revertTouchedByID.
		bumpOldSide := make(map[string][]*manifest.Manifest, len(bumps))
		if len(bumps) > 0 {
			// S1 (delta review on 5f61d389, HIGH — supersedes P3/Q1/Q3
			// entirely, all three REMOVED): this render runs in RunOnce
			// BEFORE upgradeModule executes THIS SAME tick. Any decision it
			// makes about whether THIS tick's own attempt will succeed or
			// fail — P3's pure prediction, Q1's touched-digest union gated
			// on that prediction, Q3's PendingDigestActuallyRefused carry-
			// forward from a PRIOR tick — can be directly CONTRADICTED by
			// what actually happens a few lines later in the very same
			// tick, once upgradeModule runs: a TRANSIENT step-1 failure
			// recorded as "refused" one tick can still succeed and reach
			// step 4 (restarting units under the new digest) THIS tick,
			// after this render already ran old-only — 217/USER, just via
			// the render running too EARLY rather than a write failing.
			// Confirmed by the delta reviewer's own repro tests: a
			// transient refusal-then-success tick, a stale
			// PendingDigestActuallyRefused surviving a revert into an
			// unrelated later bump's own first tick, and the refused
			// branch's own digest-equality skip dropping a TOUCHED (units
			// genuinely running) digest's identity entirely.
			//
			// The structural fix: this render NEVER looks at the new
			// target's manifest, and never tries to predict or remember
			// whether THIS tick's attempt will succeed. It always renders
			// stable (b.old.Digest, the content ACTUALLY attached) union
			// every digest PendingTouchedDigests already names — content
			// some unit is GENUINELY running, per a PAST tick's own step 4,
			// never a guess about the future. Identity/sudoers union those;
			// egress renders the stable digest ONLY (unchanged from its own
			// pre-existing "keep old until commit" behavior — egress must
			// not narrow or widen ahead of the binary that will actually
			// apply it, and touched-digest union has no place there
			// either).
			//
			// The NEW digest's own identity/sudoers is rendered and
			// APPLIED separately, by upgradeModule itself
			// (applyIdentityAndSudoers), immediately before step 4's first
			// restart — so a unit about to actually run the new binary
			// always has the new digest's users/grants in place before it
			// starts, decided at the ONE point in the tick that knows
			// step 4 is actually about to happen, not several lines
			// earlier on a guess.
			for _, b := range bumps {
				// N3 (review round 11): the digest-keyed attached snapshot is
				// the AUTHORITATIVE old side — unlike previousManifests
				// (RunOnce's own ID-keyed pre-fetch disk snapshot, captured
				// fresh every tick), it is written ONLY at the moment a
				// digest was actually attached/committed, so a later tick's
				// fetch of a DIFFERENT (attempted upgrade) digest can never
				// overwrite it. previousManifests remains the fallback for
				// an entry attached by a pre-N3 build, which has no snapshot
				// on disk at all yet.
				var oldSide []*manifest.Manifest
				if bmf, err := manifest.LoadAttachedSnapshot(r.cfg.ManifestRoot, b.old.ID, b.old.Digest); err == nil && bmf != nil {
					oldSide = append(oldSide, bmf)
				} else if bmf, ok := previousManifests[b.old.ID]; ok && bmf != nil {
					oldSide = append(oldSide, bmf)
				}
				// Q1 (review round 14): union in every digest this episode
				// already TOUCHED (b.old.PendingTouchedDigests — an
				// EARLIER, now-abandoned target that reached step 4), not
				// just the stable digest — that content may still
				// genuinely be running on some unit. S1: no longer skips a
				// digest equal to b.new.Digest — the new target is never
				// rendered here at all regardless (see the render loop
				// below), so there is nothing to double-count against.
				for _, digest := range b.old.PendingTouchedDigests {
					if digest == b.old.Digest {
						continue // already covered by oldSide above
					}
					if snap, err := manifest.LoadAttachedSnapshot(r.cfg.ManifestRoot, b.old.ID, digest); err == nil && snap != nil {
						oldSide = append(oldSide, snap)
					}
				}
				if len(oldSide) == 0 {
					continue // nothing to substitute — falls back to a plain new-only render
				}
				bumpOldSide[b.new.ID] = oldSide
			}
		}
		// T2 (final review on f3339424, LOW): a module currently REVERTING
		// (desired already back at its own stable digest, but an earlier
		// abandoned target's units may still be running until THIS tick's
		// own forced restart completes) needs the SAME touched-digest union
		// bumpOldSide gives an in-flight bump. mergedManifests[id] already
		// resolves to the correct STABLE manifest for a reverting module
		// (there is nothing to substitute), but on its own it carries no
		// knowledge of PendingTouchedDigests — without this, the departing
		// digest's own users vanish from the render on the very tick its
		// units are still being stopped. Computed UNCONDITIONALLY (not
		// nested inside `len(bumps) > 0` above) because a pure revert never
		// appears in `bumps` at all: desired already resolves back to the
		// attached digest, so mount.Reconcile's own diff pairs nothing to
		// bump. pendingRevertIDs marks ANY module with a nonzero
		// PendingDigest, including one still actively bumping FORWARD
		// (bumpIDsThisTick) — excluded here since that case is already
		// fully handled by bumpOldSide above.
		revertTouchedByID := make(map[string][]*manifest.Manifest)
		for _, m := range current.AttachedModules {
			if !pendingRevertIDs[m.ID] || bumpIDsThisTick[m.ID] || len(m.PendingTouchedDigests) == 0 {
				continue
			}
			var extra []*manifest.Manifest
			for _, digest := range m.PendingTouchedDigests {
				if digest == m.Digest {
					continue // already covered by mergedManifests[id] itself
				}
				if snap, err := manifest.LoadAttachedSnapshot(r.cfg.ManifestRoot, m.ID, digest); err == nil && snap != nil {
					extra = append(extra, snap)
				}
			}
			if len(extra) > 0 {
				revertTouchedByID[m.ID] = extra
			}
		}
		if len(bumpOldSide) > 0 || len(revertTouchedByID) > 0 {
			identityManifests = make([]*manifest.Manifest, 0, len(mergedManifestsSlice)+len(bumpOldSide)+len(revertTouchedByID))
			egressManifestsSlice = make([]*manifest.Manifest, 0, len(mergedManifestsSlice))
			for id, m := range mergedManifests {
				if oldSide, isBump := bumpOldSide[id]; isBump {
					// S1: the new (bumping) manifest is NEVER appended
					// here — identity/sudoers render old ∪ touched
					// ONLY. egress keeps the stable digest ONLY
					// (oldSide[0], appended first above, unconditionally,
					// before any touched-digest is ever appended).
					identityManifests = append(identityManifests, oldSide...)
					egressManifestsSlice = append(egressManifestsSlice, oldSide[0])
					continue
				}
				identityManifests = append(identityManifests, m)
				egressManifestsSlice = append(egressManifestsSlice, m)
				if extra, isReverting := revertTouchedByID[id]; isReverting {
					// T2: identity/sudoers union in the departing
					// digest(s)' own users too — egress stays
					// stable-only, same rule as the bump path above.
					identityManifests = append(identityManifests, extra...)
				}
			}
		}

		// T1 (final review on f3339424, HIGH): snapshot THIS tick's own full
		// identity manifest set for upgradeModule's own pre-step-4 render to
		// reuse (append its new target, refuse if this is nil-with-skipped)
		// — see tickIdentityManifests' own doc for why passing it only the
		// bumping module's own manifests was the bug.
		r.tickIdentityManifests = identityManifests
		r.tickIdentityRenderSkipped = false

		// Render /etc/passwd, /etc/group, /etc/shadow, /etc/gshadow from the
		// merged (fresh + cached/breadcrumb-fallback) manifest set BEFORE any
		// attach kicks off systemd units that reference platform-managed
		// users via `User=`. Sudoers follows so any grant referencing the
		// just-rendered users is in place before service start. Both
		// renderers are idempotent and run every reconcile tick — atomic
		// writes are no-ops if contents match.
		_ = r.applyIdentityAndSudoers(identityManifests, "reconciler:")

		// Node-wide egress enforcement, same pattern as identity/sudoers just
		// above: one shared nftables OUTPUT chain governs the WHOLE node, so
		// it must reflect the UNION of every currently-desired module's
		// declared policy, recomputed fresh from the same
		// egressManifestsSlice every tick — never a single module's own
		// Policy.Apply, which would let whichever module happens to
		// reconcile last silently clobber every sibling's intent (see
		// security.UnionEgressPolicy's doc comment for the full history of
		// that bug).
		//
		// Gated on the SAME mustSkipRender predicate as identity/sudoers
		// above (review finding N3/R2-N3): reachable only when every
		// candidate resolved, so there is no separate "unresolved but
		// enforcement looked off" case left to guard here — that case IS
		// mustSkipRender, handled by skipping this whole block.
		//
		// SkipEgress (see its own doc on ReconcilerConfig) additionally
		// excludes any CLI-built reconciler — identity/sudoers above still
		// render normally; only the node-wide nft chain, which the
		// long-running service exclusively owns, is left untouched here.
		if r.cfg.SkipEgress {
			r.cfg.OnError("reconciler:egress_skipped", errors.New(
				"egress is service-owned; this CLI reconcile pass left the node-wide nft chain untouched"))
		} else {
			egressPolicies := make([]*security.Policy, 0, len(egressManifestsSlice))
			for _, m := range egressManifestsSlice {
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
				// SDWAN's interfaces + peer endpoints (IMP-13645c4df90a) — applies
				// whenever enforcement is ON (this branch), same as protectedHosts;
				// the else branch below (enforcement off) removes the whole chain,
				// so there is no separate "off" case to gate this on.
				var extras security.EgressExtras
				if r.cfg.ExtraEgress != nil {
					extras = r.cfg.ExtraEgress()
				}
				if err := security.ApplyEgressAllowlistWithExtras(ctx, r.cfg.MountRunner, egressAllow, protectedHosts, extras); err != nil {
					r.cfg.OnError("reconciler:egress", err)
				}
			} else {
				// No currently-desired module declared an egress policy this
				// tick (e.g. the one module that did was just detached) — and
				// (per the mustSkipRender gate above) every candidate resolved,
				// so this is a genuine "nobody wants enforcement", not an
				// unresolved view. Best-effort teardown so a stale restrictive
				// chain never lingers past the module that asked for it. Error
				// ignored deliberately: "no such chain" is the common, expected
				// case.
				_ = security.RemoveEgressAllowlist(ctx, r.cfg.MountRunner)
			}
		}
	}

	// Reassert the platform-assigned hostname every reconcile tick — live
	// /etc/hostname + the running kernel hostname — the same way the agent
	// owns /etc/passwd. Idempotent; a no-op when no authoritative source is
	// present this boot (e.g. a non-QEMU/cloud node with no instance_name
	// fw-cfg, where the hostname is set by cloud-init and left untouched here).
	if name := desiredHostname(); name != "" {
		changed, err := applyHostname("", name, true)
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
	// mounts: fresh erofs pull + verify + mount, then materialize, then
	// attachModuleServices) and toReattach (already-mounted but
	// manifest-changed: skips the pull/mount via attachModule's idempotency,
	// re-materializes, then re-runs attachModuleServices to pick up the new
	// units). In BOTH loops the file materialization is gated ahead of the
	// service start, and a refused materialization skips the start entirely.
	// Each successful attach refreshes the
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
		// A render-skipped tick (mustSkipRender above) rendered no users,
		// sudoers or egress this tick, so a unit started now would run against
		// identities that were never rendered (217/USER), and the stamp below
		// would tell the next tick the attach was done. Leave the module
		// pending: it is not recorded as attached, so the next trusted tick
		// attaches it (IMP-1023e79cc82d).
		if mustSkipRender {
			r.noteUnconverged("reconciler:attach_deferred_render_skipped", mod.ID, fmt.Errorf("module %s: attach deferred, this tick's identity render was skipped", mod.ID))
			continue
		}
		mf, ok := manifests[mod.ID]
		if !ok {
			r.noteUnconverged("reconciler:missing_manifest", mod.ID, fmt.Errorf("module %s: manifest not loaded", mod.ID))
			r.composeFailed.Store(true)
			continue
		}
		changedUnits, err := r.attachModule(ctx, mod, mf)
		if err != nil {
			r.noteUnconverged("reconciler:attach", mod.ID, fmt.Errorf("module %s: %w", mod.ID, err))
			r.composeFailed.Store(true)
			// M8 (review round 9, cleanup): this loop never handles a version
			// bump (RunOnce's own partition, right after mount.Reconcile,
			// keeps every bump out of toAttach/toDetach entirely) — a mod
			// reaching this branch is always a genuine fresh attach, so a
			// failure here leaves it simply unattached until a later tick's
			// attach succeeds, with no OLD digest anywhere to have left down.
			continue
		}
		mod.Units = mf.UnitNames()
		current.AttachedModules = append(current.AttachedModules, mod)
		current.LastAttachedManifestHashes[mod.ID] = r.attachStamp(mod.ID, mf)
		// N3 (review round 11): persist THIS digest's manifest content,
		// independent of the ID-keyed "latest fetch" cache a LATER tick's
		// fetch of a different (attempted upgrade) digest will overwrite —
		// see manifest.SaveAttachedSnapshot's own doc.
		if err := manifest.SaveAttachedSnapshot(r.cfg.ManifestRoot, mod.ID, mod.Digest, mf); err != nil {
			r.cfg.OnError("reconciler:attached_snapshot_save", fmt.Errorf("module %s digest %s: %w", mod.ID, mod.Digest, err))
		}
		if r.hotReconcileIfNeeded(mod, mf, stateWasEmpty, outgoingPaths[mod.ID], desiredForLayers) {
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
			// AND DO NOT START THE UNITS. Starting them here would run the new
			// unit definitions against content that was never written — the
			// deploy-4 shape. Declining leaves whatever is already running
			// untouched — always accurate here (M8, review round 9, cleanup):
			// this loop never handles a version bump (see the earlier NOTE in
			// this same loop), so "whatever is already running" is either
			// nothing (a genuine fresh attach) or an unrelated module, never
			// an old digest this same attempt already stopped.
			continue
		}
		// X2: thread changedUnits (not nil) — a fresh attach can still carry
		// a real confinement change on a pivot node where compose already
		// started the unit with stale drop-ins before this tick's own
		// attachModule call ran.
		r.attachModuleServices(ctx, current, mod, mf, changedUnits)
	}

	// In-place upgrades (round 9) — every version bump partitioned out of
	// toDetach/toAttach above, run through upgradeModule instead of the
	// ordinary detach-then-attach loops. See upgradeModule's own doc for
	// the full step ordering and the HARD invariant it upholds (never
	// leave a previously-running module stopped).
	sortedBumps := make([]moduleUpgrade, len(bumps))
	copy(sortedBumps, bumps)
	sort.Slice(sortedBumps, func(i, j int) bool { return sortedBumps[i].new.Priority < sortedBumps[j].new.Priority })
	for _, u := range sortedBumps {
		newMf, ok := manifests[u.new.ID]
		if !ok {
			r.noteUnconverged("reconciler:missing_manifest", u.new.ID, fmt.Errorf("module %s: manifest not loaded", u.new.ID))
			continue
		}
		// N3 (review round 11): prefer the digest-keyed attached snapshot for
		// oldMf too (oldUnitNames' own pre-round-9-entry fallback) — same
		// staleness reasoning as the identity/egress union above.
		oldMf := previousManifests[u.old.ID]
		if snap, err := manifest.LoadAttachedSnapshot(r.cfg.ManifestRoot, u.old.ID, u.old.Digest); err == nil && snap != nil {
			oldMf = snap
		}
		r.upgradeModule(ctx, current, u, newMf, oldMf, outgoingPaths[u.new.ID], desiredForLayers, stateWasEmpty)
	}

	// Re-attach loop for manifest-only changes. attachModule is
	// idempotent on its mount + cosign + fs-verity + policy steps
	// (cached results return immediately) — the meaningful work here is
	// the attachModuleServices call below, which writeIfChanged-s each unit
	// file and runs daemon-reload only when at least one wrote. It runs only
	// after the materialization is known to have succeeded.
	for _, mod := range mount.ModuleStack(toReattach).SortByPriority() {
		// Q4 (review round 14, LOW): moved to the very top of this loop
		// body, above attachModule and hotReconcileIfNeeded — see this
		// call's own doc a little further down (still explaining WHY it
		// exists) for the full reasoning. Before this fix, both of those
		// calls could `continue` before this branch was ever reached, so a
		// reattach that was ITSELF struggling (the exact tick this priority
		// retry matters most) silently starved it — the "try it again
		// BEFORE ANYTHING ELSE" promise in that doc was not actually true
		// while this call sat below two things that could skip it.
		if pendingRevertIDs[mod.ID] {
			// P9 (review round 13, LOW, rule-1 edge): union PendingUndoUnits
			// across EVERY matching row for this ID, not just the first —
			// the M4 duplicate-state-entry case (see O8(a)'s own doc,
			// below) means a second row could independently carry its own
			// stuck departing unit(s) that the first row's own value never
			// mentions. Reading only the first left that second row's
			// stuck unit unattended by this priority retry forever.
			var pendingUndo []string
			for _, m := range current.AttachedModules {
				if m.ID == mod.ID {
					pendingUndo = unionStrings(pendingUndo, m.PendingUndoUnits)
				}
			}
			if len(pendingUndo) > 0 {
				r.retryPendingUndoUnits(ctx, current, mod.ID, pendingUndo)
			}
		}
		// Same rule as the attach loop: no reattach and no stamp on a
		// render-skipped tick (IMP-1023e79cc82d). Placed after the pending-undo
		// retry above, which restarts units that already exist against users
		// that already rendered.
		if mustSkipRender {
			r.noteUnconverged("reconciler:reattach_deferred_render_skipped", mod.ID, fmt.Errorf("module %s: reattach deferred, this tick's identity render was skipped", mod.ID))
			continue
		}
		mf, ok := manifests[mod.ID]
		if !ok {
			continue
		}
		// W1 (IMP-caef5c00d63f round W): changedUnits names every unit whose
		// security drop-in this SAME call actually rewrote — threaded into
		// every attachModuleServices(Opts) call below that follows it for
		// THIS module, so a confinement-only change (no unit body change at
		// all) still reaches an already-running unit instead of silently
		// sitting on disk unapplied until something else restarts it.
		changedUnits, err := r.attachModule(ctx, mod, mf)
		if err != nil {
			r.noteUnconverged("reconciler:reattach", mod.ID, fmt.Errorf("module %s: %w", mod.ID, err))
			continue
		}
		current.LastAttachedManifestHashes[mod.ID] = r.attachStamp(mod.ID, mf)
		// N3 (review round 11): a manifest-only edit at this STABLE digest
		// still changes what "the content attached at this digest" means —
		// refresh the snapshot so a LATER bump's old-side union reads the
		// current content, not whatever was true at the original attach.
		if err := manifest.SaveAttachedSnapshot(r.cfg.ManifestRoot, mod.ID, mod.Digest, mf); err != nil {
			r.cfg.OnError("reconciler:attached_snapshot_save", fmt.Errorf("module %s digest %s: %w", mod.ID, mod.Digest, err))
		}
		if r.hotReconcileIfNeeded(mod, mf, stateWasEmpty, outgoingPaths[mod.ID], desiredForLayers) {
			// Same re-queue as the attach loop: a refused materialization must
			// not leave a stamp claiming this manifest is materialized, and
			// must not leave the heartbeat claiming it is running — and must
			// not restart the units against content that is not there.
			delete(current.LastAttachedManifestHashes, mod.ID)
			unmaterialized[mod.ID] = true
			continue
		}
		if pendingRevertIDs[mod.ID] {
			// P4 (review round 13, MEDIUM) / Q4 (review round 14, LOW): a
			// departing unit N8's own undo could not restart is a genuine
			// OUTAGE, same reasoning as upgradeModule's OWN top-of-function
			// priority retry (O6, review round 12) — tried BEFORE ANYTHING
			// ELSE for this module, including attachModule/hotReconcileIfNeeded
			// above (see the top-of-loop call site, moved there by Q4).
			// retryPendingUndoUnits itself already clears an entry ONLY once
			// confirmed active and leaves a still-failing one both in the
			// list and visible (its own doc, O6).
			// O8(d) (review round 12): PendingDigest is now set the MOMENT an
			// upgrade attempt begins (upgrade.go, before step 1), for N4
			// visibility of a mount/policy/hot-reconcile refusal that never
			// gets far enough to touch a unit at all. Consulting bare
			// PendingDigest presence here (as this revert path always used to)
			// would therefore force-restart a unit NOTHING ever touched —
			// exactly the class of Rule-1 violation O8(a) fixed elsewhere in
			// this round. PendingDigestUnitsTouched is the narrower fact: it
			// only flips true once upgradeModule is actually about to issue
			// step 4's restart.
			// P9 (review round 13, LOW, rule-1 edge): OR PendingDigestUnitsTouched
			// and union PendingIntroducedUnits across EVERY matching row for
			// this ID, not just the first — same M4 duplicate-state-entry
			// reasoning as O8(a) (below) and the PendingUndoUnits read above.
			// A second row's own attempt could have touched units the first
			// row's own value says nothing about; force a restart if ANY row's
			// attempt did, since touched units are touched regardless of which
			// row recorded them.
			unitsTouched := false
			var introducedUnits []string
			for _, m := range current.AttachedModules {
				if m.ID == mod.ID {
					if m.PendingDigestUnitsTouched {
						unitsTouched = true
					}
					introducedUnits = unionStrings(introducedUnits, m.PendingIntroducedUnits)
				}
			}
			if !unitsTouched {
				// Nothing was ever touched by the abandoned attempt (it never
				// got past step 1-3) — an ordinary, UNFORCED reattach is
				// correct: the stable digest's units were never disturbed, so
				// there is nothing to recover. Just clear the bookkeeping and
				// let the ordinary attachModuleServices path below run (a
				// no-op unless the manifest itself genuinely changed).
				for i, m := range current.AttachedModules {
					if m.ID == mod.ID {
						current.AttachedModules[i].PendingDigest = ""
						current.AttachedModules[i].PendingDigestAttempts = 0
						current.AttachedModules[i].PendingDigestLastAttemptUnix = 0
						current.AttachedModules[i].PendingConflictRecoveryAttempted = false
						current.AttachedModules[i].PendingUndoUnits = nil
						current.AttachedModules[i].PendingIntroducedUnits = nil
						current.AttachedModules[i].PendingTouchedDigests = nil
						// S1 (delta review on 5f61d389): this revert episode is
						// fully resolved (nothing was ever touched) — clear
						// Q5's own reset flag too, per team-lead's explicit
						// instruction, even though a fresh upgrade attempt's own
						// re-target branch (upgrade.go) already resets it before
						// this would otherwise matter.
						current.AttachedModules[i].PendingRevertAttemptsReset = false
						// V1 (delta review on 83d056ea): this episode's own
						// pre-upgrade baseline is resolved along with everything
						// else it was captured for.
						current.AttachedModules[i].PendingPreUpgradeFailed = nil
					}
				}
				pruneDropInSnapshotsForModule(r.cfg.StatePath, mod.ID, "")
				if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
					r.cfg.OnError("reconciler:revert_pending_save", fmt.Errorf("module %s: could not persist the cleared PendingDigest for a never-touched attempt: %w", mod.ID, err))
				}
				// Round Y: no un-stamp on a withheld confinement restart —
				// see attachModuleServices' own doc. The module's manifest
				// hash stamp reflects whether ITS OWN content is applied,
				// which this call already achieved (the write + reload
				// happened; only a running-process restart was withheld);
				// reconcileStaleConfinement reports and, where permitted,
				// heals the running process independently, every tick,
				// straight from /proc.
				r.attachModuleServices(ctx, current, mod, mf, changedUnits)
			} else {
				// N2 (review round 11): this entry is a REVERT of a
				// failed/incomplete upgrade attempt, not an ordinary manifest
				// edit — the body on disk is UNCHANGED (same stable digest, same
				// manifest content as before the failed attempt), so the
				// ordinary attachModuleServices call below would see every unit
				// as Skipped and, without ForceRestartActive, never actually
				// restart one that the failed attempt left running the OLD
				// binary in a bad state — only `start` a genuinely inactive one.
				// Force it, exactly like upgradeModule's own step 4, then clear
				// PendingDigest now that the stable digest is reconfirmed as the
				// converged target.
				//
				// O3 (review round 12, MEDIUM): this force-restart had NO backoff
				// at all — a persistently failing revert retried on EVERY tick
				// forever, the exact bug N2's own backoff exists to prevent for
				// the ordinary retry path. Gated by the SAME backoffAllows the
				// upgradeModule side uses.
				if allowed, wait, elapsed := backoffAllows(pendingAttemptsByID[mod.ID], pendingLastAttemptByID[mod.ID]); !allowed {
					r.noteUnconverged("reconciler:revert_pending_backoff", mod.ID, fmt.Errorf(
						"module %s: revert force-restart backed off after %d attempts (%s since the last, %s remaining before the next) — not abandoned, a later reconcile tick retries",
						mod.ID, pendingAttemptsByID[mod.ID], elapsed.Round(time.Second), (wait-elapsed).Round(time.Second)))
					continue
				}
				for i, m := range current.AttachedModules {
					if m.ID == mod.ID {
						current.AttachedModules[i].PendingDigestAttempts++
						current.AttachedModules[i].PendingDigestLastAttemptUnix = nowForUpgradeBackoff().Unix()
						break
					}
				}
				if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
					r.cfg.OnError("reconciler:revert_pending_attempt_save", fmt.Errorf("module %s: could not persist the revert attempt counter: %w", mod.ID, err))
				}
				if _, err := r.attachModuleServicesOpts(ctx, mod, mf, true, true, nil); err != nil {
					// F8 (V1 second delta review): a FAILED revert attempt
					// deliberately does NOT clear PendingPreUpgradeFailed/
					// PendingDigestUnitsTouched/PendingConflictRecoveryAttempted
					// here — this episode is still unresolved, a later tick
					// retries the SAME revert, and it must keep reading the
					// SAME persisted baseline it already captured rather than
					// treating a fresh retry as a brand-new episode. Only a
					// revert that genuinely SUCCEEDS (below) clears them.
					r.noteUnconverged("reconciler:revert_pending_digest", mod.ID, fmt.Errorf(
						"module %s: force-restart on revert failed: %w (PendingDigest left set — a later tick retries)", mod.ID, err))
					continue
				}
				// O4 (review round 12, MEDIUM) / P2 (review round 13, HIGH): a
				// unit that exists ONLY in an abandoned PENDING digest (started
				// during a failed upgrade attempt's own step 4, e.g. a renamed
				// service's new-only unit) is never named by the stable
				// digest's own manifest (mf here) and so is never touched by
				// the force-restart above — it would otherwise stay running
				// forever, orphaned, once PendingDigest is cleared below and
				// nothing ever asks about it again.
				//
				// P2's own fix: read introducedUnits (mount.Module.
				// PendingIntroducedUnits, captured above BEFORE this loop
				// clears it) rather than loading ONE digest's manifest snapshot
				// from the N3 store. O4's original design looked up
				// pendingDigestByID[mod.ID] — the CURRENT PendingDigest only —
				// which silently lost track of an EARLIER, now-abandoned
				// target's own introduced units the moment a re-target moved
				// PendingDigest on to a third digest (d2 touched -> d3 refused
				// -> revert: d2's own new-only unit was invisible here, since
				// pendingDigestByID[mod.ID] pointed at d3's snapshot, which
				// never mentions it). PendingIntroducedUnits is the ACCUMULATED
				// union across every touched target this whole episode, so it
				// has no such blind spot. Stopping and cleaning these up IS
				// rule-(2) — a genuine reversion away from the abandoned
				// version(s) — not a refusal side effect.
				if len(introducedUnits) > 0 {
					r.stopDepartingUnits(ctx, mod.ID, introducedUnits, mf.UnitNames())
				}
				// O8(a) (review round 12, RULE-1 EDGE): clear EVERY entry with this
				// ID, not just the first match — no `break`. The M4 duplicate-
				// state-entry case (two AttachedModules rows for the same module
				// ID; see TestReconcile_DuplicateStateEntryNeverStopsTheLiveModule)
				// means a second entry could independently carry its own
				// PendingDigest. Stopping at the first match left that second
				// entry's PendingDigest stuck forever: pendingRevertIDs is built
				// from this SAME slice keyed by ID, so a module the revert just
				// SUCCEEDED on would still read as pending-a-revert on the very
				// next tick and force-restart it again — an unforced, invisible
				// restart of an already-healthy unit, forever.
				for i, m := range current.AttachedModules {
					if m.ID == mod.ID {
						current.AttachedModules[i].PendingDigest = ""
						current.AttachedModules[i].PendingDigestAttempts = 0
						current.AttachedModules[i].PendingDigestLastAttemptUnix = 0
						current.AttachedModules[i].PendingConflictRecoveryAttempted = false
						current.AttachedModules[i].PendingUndoUnits = nil
						current.AttachedModules[i].PendingIntroducedUnits = nil
						// P5 (review round 13): PendingDigestUnitsTouched itself
						// was never explicitly reset here — P2's own sticky fix
						// (round 13) made it correctly SURVIVE a re-target, but
						// a successful REVERT (unlike a commit, which replaces
						// the whole entry with a fresh struct) mutates fields in
						// place and had no line clearing this one at all. Left
						// as true forever, a LATER, completely unrelated bump of
						// this same module ID would start its very first tick
						// already reading "touched" — skipping P3's own
						// predicted-refusal check and applying the sudoers/
						// identity union immediately, before that new episode's
						// own step 2 has run at all.
						current.AttachedModules[i].PendingDigestUnitsTouched = false
						// Q1 (review round 14): PendingIntroducedUnits' own
						// sibling — cleared for the same reason, same place.
						current.AttachedModules[i].PendingTouchedDigests = nil
						// S1 (delta review on 5f61d389): clear Q5's own reset
						// flag here too, now that this revert's forced restart
						// has genuinely completed — per team-lead's explicit
						// instruction, in BOTH revert-completion branches.
						current.AttachedModules[i].PendingRevertAttemptsReset = false
						// V1 (delta review on 83d056ea): same reasoning, both
						// revert-completion branches.
						current.AttachedModules[i].PendingPreUpgradeFailed = nil
					}
				}
				// N7 (review round 11): the abandoned target's persisted drop-in
				// snapshot is no longer needed. O2 (review round 12): prune EVERY
				// leftover snapshot file for this module ID, not just the one
				// abandoned target — nothing is pending after a revert, so
				// nothing should be kept.
				pruneDropInSnapshotsForModule(r.cfg.StatePath, mod.ID, "")
				if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
					r.cfg.OnError("reconciler:revert_pending_save", fmt.Errorf("module %s: could not persist the cleared PendingDigest after reverting: %w", mod.ID, err))
				}
			}
		} else {
			// Round Y: ordinary manifest-only reattach — no un-stamp on a
			// withheld confinement restart (see attachModuleServices' own
			// doc and the never-touched-revert branch above).
			r.attachModuleServices(ctx, current, mod, mf, changedUnits)
		}
		// round 9: refresh the STORED entry's Units for a manifest-only
		// change too (same digest, edited services) — upgradeModule's own
		// future delta-stop for a LATER version bump of this same module
		// reads old.Units, and a stale list there (from before this
		// manifest edit) would misjudge which units are genuinely
		// departing on that later bump.
		for i, m := range current.AttachedModules {
			if m.ID == mod.ID {
				current.AttachedModules[i].Units = mf.UnitNames()
				break
			}
		}
	}

	// K4 (review round 6): bound J3's carry-forward to units belonging to a
	// module THIS TICK STILL CONSIDERS RELEVANT — desired (still assigned),
	// manifestFetchFailed (assigned, but this tick's fetch failed — the
	// partial-view case J3 exists for), or retained (currently attached,
	// might resolve through a stale-manifest fallback). Without this bound,
	// a module that is GENUINELY UNASSIGNED (removed from the platform's
	// list entirely, a clean fetch that simply excludes it) can never become
	// "attempted" again — nothing will ever call applyModuleSecurityPolicy
	// for it — so its previously-published refusal would carry forward
	// FOREVER under J3's original unbounded rule, a permanent stale alarm
	// with no path to clearing. previousManifests (K2b's snapshot, captured
	// before this tick's fetch loop) is the fallback source for a module
	// whose fetch just failed and therefore has no fresh entry in
	// `manifests`.
	relevantUnits := make(map[string]bool)
	addRelevantUnits := func(moduleID string) {
		if mf, ok := manifests[moduleID]; ok && mf != nil {
			for _, u := range mf.UnitNames() {
				relevantUnits[u] = true
			}
			return
		}
		if mf, ok := previousManifests[moduleID]; ok && mf != nil {
			for _, u := range mf.UnitNames() {
				relevantUnits[u] = true
			}
		}
	}
	for _, m := range desired {
		addRelevantUnits(m.ID)
	}
	for id := range manifestFetchFailed {
		addRelevantUnits(id)
	}
	for _, m := range retained {
		addRelevantUnits(m.ID)
	}

	// Publish this pass's complete security-fail-closed result in ONE Store
	// (G4) — attachModule (called from both loops above) only ACCUMULATES
	// into the pending, non-atomic field; this is the one place the
	// atomically-published value a concurrent heartbeat reads actually moves,
	// so no reader can observe a mid-pass partial result.
	r.publishSecurityFailClosed(current, relevantUnits)

	// Deferred leaver prunes — after both attach loops so every desired
	// module's tree is mounted before any surviving-layer resolution.
	// desiredForLayers, not `desired` (review finding N3): a retained module
	// this tick could not fetch a fresh manifest for is still genuinely
	// mounted and serving content, and survivingLayerDirs must be able to see
	// it — omitting it here would make a REAL leaver's prune read that
	// module's paths as unclaimed and delete them.
	r.processPendingPrunes(desiredForLayers)

	// Filter out detached modules from current — both from the attached
	// list and from the manifest-hash map (so a later re-add doesn't
	// see a stale hash and skip the initial attach). Same digest-keyed
	// definition of "retained" as the one computed earlier for the
	// render/hot-prune guards (retainedAfterDetach) — reusing it here keeps
	// the two in permanent agreement rather than two independent filters
	// that could silently drift apart.
	if len(toDetach) > 0 {
		detachedIDs := make(map[string]bool, len(toDetach))
		for _, m := range toDetach {
			detachedIDs[m.ID] = true
		}
		current.AttachedModules = retainedAfterDetach(current.AttachedModules, toDetach)
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
		// FAIL CLOSED on an unresolved root-mode probe (IMP-81aa3112): using
		// the swallow-to-chroot lifecycle.PivotAwareRootMode() here would read
		// a statfs failure as "definitely chroot" and take the MUTATING else
		// branch below — mounting a second overlay. On a node that is
		// genuinely pivot-booted that shares the live root's upperdir/workdir
		// with a second mount, which the kernel documents as undefined
		// behavior (see the RootModeNative comment just below). The
		// asymmetry is the same one already established for detachModule's
		// unmountWouldStripLiveRoot: an unreadable probe resolves to the
		// non-mutating outcome, never the mutating one. Declining costs one
		// deferred tick (current.UnionMounted is left exactly as it was);
		// guessing wrong costs a kernel-UB double mount.
		rootMode, rmErr := pivotAwareRootModeChecked()
		if rmErr != nil {
			// noteUnconverged (not a bare OnError) so this pass is not
			// reported as having converged: the union step was declined, so
			// whatever lowerdir is live right now may already be stale
			// relative to current.AttachedModules, and the caller must know
			// this tick did not resolve that.
			r.noteUnconverged("reconciler:root_mode_probe_failed", "", fmt.Errorf(
				"could not determine pivot-vs-chroot root mode this tick (%w); declining the union-mount step rather than guessing — a wrong chroot guess on an actually-pivoted root risks a double overlay mount", rmErr))
		} else if rootMode == lifecycle.RootModeNative {
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

	// W2/X3/X4 (IMP-caef5c00d63f): once-per-boot-composition drop-in
	// reverification — see confinement_recheck.go's own doc. Runs after both
	// attach loops and every upgrade have settled for this tick, over
	// current.AttachedModules' own final state.
	r.reconfirmConfinementIfNeeded(ctx, current, manifests, mustSkipRender)

	// Round Y (IMP-caef5c00d63f): the stateless confinement-staleness pass —
	// see confinement_probe.go's own doc. Runs after the recheck above (so a
	// drop-in it just rewrote is probed against its OWN fresh write, not a
	// stale one) and before reportKnownDegradedUnits, over every attached,
	// manifest-resolved, N4-eligible module's own units.
	r.reconcileStaleConfinement(ctx, current, manifests)

	// V1 (delta review on 83d056ea, point 3 — visibility): re-check every
	// unit an earlier V1 exemption let commit despite it, on EVERY ordinary
	// tick, not just while some OTHER bump is in flight — see this
	// function's own doc for why nothing lighter already covers this.
	r.reportKnownDegradedUnits(ctx, current)

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

// reportKnownDegradedUnits (V1, delta review on 83d056ea, point 3 —
// visibility) re-checks every unit an EARLIER V1 exemption let commit
// despite a still-failing settle check, on EVERY ordinary reconcile tick —
// not gated on a bump being in flight — so the module stays visibly
// degraded rather than reporting once during the commit tick and going
// quiet. Searched for a lighter existing signal first and found none:
// ModuleVerifyState is opt-in per manifest (`verify:` probes — claude-tmux's
// own credential unit, the motivating case, declares none), and
// convergeFailures itself is reset every pass (same reason
// resetSecurityFailClosed is) — nothing in this codebase already re-samples
// an already-committed, otherwise-unchanged module's own unit health on a
// steady-state tick.
//
// F1 (V1 second delta review, MEDIUM — verified): this must NOT go through
// noteUnconverged/convergeFailures. tasks/handlers/config.go's SyncHandler
// FAILS the apply_config task whenever ConvergenceFailures() is non-empty
// (IMP-f1c1e6d61104) specifically so the server's config_drift_sensor.rb
// stops suppressing drift on a node that materialized nothing. A pre-
// existing failure this exemption already proved is NOT a regression would,
// through that same channel, fail EVERY apply_config task forever — an
// endless drift → remediate → fail loop across the whole node, for a
// failure that already existed before this upgrade and that a task
// succeeding despite it is the entire point of exempting. No existing
// heartbeat field already carries a per-unit health/degraded signal either
// (HeartbeatPayload's own *SecurityFailClosedUnits fields are narrowly
// about security drop-in writes, not general unit health; ModuleVerifyState
// is the opt-in probe checked above) — reported through r.cfg.OnError
// directly instead: the log/stderr sink every OnError call already reaches,
// with no server-side contract change. A dedicated heartbeat field is a
// follow-up for the platform side, not this commit.
func (r *Reconciler) reportKnownDegradedUnits(ctx context.Context, current *mount.State) {
	for i, m := range current.AttachedModules {
		if len(m.KnownDegradedUnits) == 0 {
			continue
		}
		var stillDegraded []string
		for _, unit := range m.KnownDegradedUnits {
			active, _ := systemd.IsActive(ctx, r.cfg.MountRunner, unit)
			result, _ := systemd.ShowProperty(ctx, r.cfg.MountRunner, unit, "Result")
			if active || result == "success" {
				continue // recovered — drop it, no separate event
			}
			stillDegraded = append(stillDegraded, unit)
			r.cfg.OnError("reconciler:known_degraded_unit", fmt.Errorf(
				"module %s: unit %s remains degraded (Result=%q) since an earlier upgrade committed despite it (V1: it was already failing before that whole episode started) — operator action needed (e.g. configure the missing credential); not blocking any commit, and NOT counted as a convergence failure (F1: an apply_config task must not fail forever over a pre-existing condition), just staying visible until it recovers",
				m.ID, unit, result))
		}
		current.AttachedModules[i].KnownDegradedUnits = stillDegraded
	}
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
//	services                       -> systemd units (name, exec, deps, health, user)
//	users                          -> /etc/passwd entries the agent reconciles
//	groups                         -> /etc/group entries
//	security                       -> capability/userns/egress drop-ins
//	sudoers                        -> /etc/sudoers.d grants
//	init                           -> init_start/stop/restart lifecycle hooks
//	service_capabilities_presence  -> W4 (IMP-caef5c00d63f round W): a
//	  TOP-LEVEL marker (manifest.Manifest.ServiceCapabilitiesPresence, NOT
//	  nested under "security") that changes how a service's OWN declared
//	  `capabilities: []` resolves — see security.ResolveServiceCapabilities'
//	  caller doc: without the marker, a declared [] is untrustworthy (a
//	  pre-stage-1 server sends [] for every service regardless of the
//	  manifest) and falls back to inheriting the module's ceiling; with it,
//	  [] means the operator explicitly granted zero capabilities. A server
//	  re-publish that flips ONLY this marker (capabilities/services/security
//	  blocks otherwise byte-identical) therefore changes the RESOLVED
//	  capability set a service actually runs with — exactly the class of
//	  change sameComposition's own doc says this set exists to catch — but
//	  was invisible to behaviouralManifestKey before this, since it lives
//	  outside every key already listed here.
var behaviouralManifestFields = []string{"services", "users", "groups", "security", "sudoers", "init", "service_capabilities_presence"}

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
		// The platform's blob-signature bundle rides the manifest (like
		// FsverityRoot); Pull materialises it at bundlePath. Empty when the
		// platform published none — the verifier, when enforcing, then
		// refuses by name. See internal/verify/doc.go.
		CosignBundleB64: mod.CosignBundleB64,
	}
	cfsPath, bundlePath, err := r.cfg.Puller.Pull(ref)
	if err != nil {
		return fmt.Errorf("pull: %w", err)
	}
	// Signature gate. cfg.Verifier is whatever ResolveModuleVerifier chose for
	// this site from the operator's module-signing policy — verify.AlwaysOK
	// by DEFAULT, a static-key CosignVerifier (or its audit wrapper) once the
	// operator opts in. Fails closed on any error.
	if err := r.cfg.Verifier.VerifyBlob(ctx, cfsPath, bundlePath); err != nil {
		return fmt.Errorf("verify cosign: %w", err)
	}
	// fs-verity arm. cfg.Fsverity is whatever ResolveModuleFsverity chose for
	// this site: nil by DEFAULT (no check), measure-only once the operator opts
	// in. mod.FsverityRoot, NOT mod.Digest: Digest is the sha256 of the blob
	// bytes, FsverityRoot is the kernel's Merkle-tree root over the same file;
	// passing Digest compared two unrelated hashes. A missing root is refused by
	// the checker itself (FsVerifier.VerifyDigest), so an enforcing checker fails
	// closed on it and a measuring one reports it. A branch here refused it under
	// every mode, which is why no site could ever wire this arm.
	if r.cfg.Fsverity != nil {
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
// SecurityFailClosedError is attachModule's error for EVERY refusal
// applyModuleSecurityPolicy can produce — distinct from a bare fmt.Errorf so
// a caller can `errors.As` it to learn WHICH units refused and WHY, rather
// than parsing the message text. Added for J2 (review round 5): AttachOne
// runs inside the `powernode-agent attach` CLI's own short-lived process
// (see AttachOne's doc comment), which exits immediately after this error
// propagates back to it — there is no daemon Reconciler instance left
// running to read SecurityFailClosedUnits() from, so the CLI's own
// output/exit code is the only durable signal this refusal ever gets there.
// The long-running daemon's RunOnce path keeps using
// SecurityFailClosedUnits()/buildHeartbeat as before; this type exists for
// the OTHER caller.
//
// K5a (review round 6): originally only the drop-in-write-failure branch
// used this type — an unapproved privileged request or an invalid policy
// still surfaced as a bare fmt.Errorf, so RunAttach's attachErrorResult
// mapped them to ExitMountFailed (a mount/pull/verify code) even though they
// are the SAME kind of event as a drop-in failure: applyModuleSecurityPolicy
// refusing to let this module attach unconfined. Every applyModuleSecurityPolicy
// error now wraps into this type; Units is every unit the module owns for a
// privileged/invalid-policy/Apply refusal (there is no single failing unit
// to name — the whole module refused before reaching per-unit drop-ins) and
// specifically the FAILED units for a drop-in write failure.
type SecurityFailClosedError struct {
	ModuleID string
	Units    []string
	Reason   string
}

func (e *SecurityFailClosedError) Error() string {
	return fmt.Sprintf("module %s: refusing to (re)attach/start unit(s) %v (fail closed): %s", e.ModuleID, e.Units, e.Reason)
}

// Pulled BEFORE either the detach or attach loop runs (see the RunOnce call
// site) so an artifact pull/verify/mount failure is known before anything
// about the module's existing attachment is touched. Best-effort: a
// prefetch failure surfaces via OnError here, and the normal attachModule()
// call later in this same tick attempts (and fails again, now correctly
// attributed) the same module rather than silently skipping it — so there
// is nothing for a caller to act on beyond that OnError, and this
// deliberately returns nothing (M8, review round 9: a readiness map
// returned here and never consumed by any caller — round 9's own
// in-place-upgrade work does not read it either, a stale claim the
// previous doc made — is exactly the kind of half-finished plumbing that
// invites a FUTURE caller to trust it without checking whether anything
// actually populates or honours it).
func (r *Reconciler) prefetchNewArtifacts(ctx context.Context, toAttach mount.ModuleStack) {
	for _, mod := range toAttach {
		if err := r.mountModuleArtifact(ctx, mod); err != nil {
			r.cfg.OnError("reconciler:prefetch", fmt.Errorf("module %s: %w", mod.ID, err))
		}
	}
}

// decideModuleSecurityPolicy is the PURE half of a module's security-policy
// decision — no I/O, no host mutation, safe to call any number of times for
// the same manifest with no side effects whatsoever (K1, review round 6,
// CRITICAL, splitting what used to be applyModuleSecurityPolicy). Builds
// mod's Policy, gates an unapproved privileged request, validates the
// policy, and resolves per-service capability writes — every check that
// depends only on mf + policy + the operator's privileged allowlist, never
// on the filesystem or the running system.
//
// droppedCaps (K5b, review round 6) names any capability the manifest
// declared that THIS agent binary does not recognize — see
// Policy.DropUnknownCapabilities's own doc for why dropping (narrower,
// never wider) rather than refusing the whole module is the correct
// response to a version-skew name. Still pure: this function only reports
// what was dropped; emitting a warning about it is the caller's job (an
// OnError call is a diagnostic side effect, never a host mutation, but it
// does need a receiver this function deliberately doesn't have).
// PolicyDecisionReason classifies WHY decideModuleSecurityPolicy refused a
// module (round 9, point 7): the live reconcile path and the pivot
// boot-compose path each report their own operator-facing stage tag
// (reconciler:* vs compose:policy_invalid / compose:privileged_unapproved /
// compose:capabilities_invalid) for the SAME underlying decision, and losing
// that distinction when the two paths started sharing one function would be
// a real regression in pivot's existing diagnostics — see renderPivotUnits'
// own call site for how it recovers the tag via errors.As.
type PolicyDecisionReason int

const (
	// PolicyDecisionPrivilegedUnapproved: security.privileged=true without an
	// operator grant in privileged_module_ids.
	PolicyDecisionPrivilegedUnapproved PolicyDecisionReason = iota + 1
	// PolicyDecisionInvalid: policy.Validate() rejected the module-wide policy.
	PolicyDecisionInvalid
	// PolicyDecisionCapabilitiesInvalid: a service's declared capabilities
	// exceed the module's own ceiling.
	PolicyDecisionCapabilitiesInvalid
)

// PolicyDecisionError wraps decideModuleSecurityPolicy's refusal with a
// machine-readable Reason, while Error() renders identically to the bare
// error it wraps — so the live path (which only ever consumed err.Error()
// via SecurityFailClosedError.Reason before this type existed) sees
// byte-identical text and needs no changes.
type PolicyDecisionError struct {
	Reason PolicyDecisionReason
	Err    error
}

func (e *PolicyDecisionError) Error() string { return e.Err.Error() }
func (e *PolicyDecisionError) Unwrap() error { return e.Err }

// decideModuleSecurityPolicy is the PURE half of a module's security-policy
// decision — no I/O, no host mutation, safe to call any number of times for
// the same manifest with no side effects whatsoever (K1, review round 6,
// CRITICAL, splitting what used to be applyModuleSecurityPolicy). Builds
// mod's Policy, gates an unapproved privileged request, validates the
// policy, and resolves per-service capability writes — every check that
// depends only on mf + policy + the operator's privileged allowlist, never
// on the filesystem or the running system.
//
// Shared by BOTH the live reconcile path (applyModuleSecurityPolicy, via
// attachCapabilityWrites) and the pivot boot-compose path (renderPivotUnits,
// via composeCapabilityWrites) as of round 9 point 7 — previously
// renderPivotUnits carried its own inline copy of this exact decision, which
// could silently drift from this one. Two parameters exist SPECIFICALLY to
// let each caller keep its own pre-existing behaviour unchanged:
//
//   - enforcePrivileged: the live path enforces unconditionally (pass true);
//     the pivot path enforces only when the boot breadcrumb's allowlist is
//     frozen (bc.PrivilegedAllowlistFrozen) — see renderPivotUnits' own doc
//     for why an unfrozen (pre-field) set must skip the gate.
//   - capabilityWriter: the live path names units from the manifest's own ID
//     (attachCapabilityWrites, i.e. mf.ID); the pivot path names them from
//     the stack entry's module ID (composeCapabilityWrites, i.e. mod.ID).
//     These happen to agree in every case observed to date, but nothing
//     upstream of this function currently PROVES it (see FetchAndCache's
//     own outstanding ID-mismatch gap, round 9 point 10) — so this function
//     takes the writer as a parameter rather than picking one ID field
//     itself, preserving each caller's exact prior behaviour rather than
//     introducing a new assumption about when the two IDs must agree.
//
// droppedCaps (K5b, review round 6) names any capability the manifest
// declared that THIS agent binary does not recognize — see
// Policy.DropUnknownCapabilities's own doc for why dropping (narrower,
// never wider) rather than refusing the whole module is the correct
// response to a version-skew name. Still pure: this function only reports
// what was dropped; emitting a warning about it is the caller's job (an
// OnError call is a diagnostic side effect, never a host mutation, but it
// does need a receiver this function deliberately doesn't have).
func decideModuleSecurityPolicy(
	mod mount.Module,
	mf *manifest.Manifest,
	privilegedAllow []string,
	enforcePrivileged bool,
	capabilityWriter func(mf *manifest.Manifest, policy *security.Policy) ([]security.UnitCapabilities, []string, error),
) (policy *security.Policy, unitAllow map[string][]string, droppedCaps []string, err error) {
	// Point 10 (review round 9), second entry point: refuse before building
	// ANY policy from mf when its own declared ID disagrees with mod.ID —
	// mirrors FetchAndCache's own refusal (manifest/loader.go) at the fetch
	// boundary, closing the same gap at the boundary a caller who already
	// holds an in-memory *manifest.Manifest crosses instead (e.g. a
	// breadcrumb/cache fallback manifest resolved for a DIFFERENT module ID
	// than the one actually being decided for). An empty mf.ID makes no
	// claim at all and is not itself a mismatch — same leniency
	// FetchAndCache applies, since many fixtures across this codebase
	// simply omit it.
	if mf != nil && mf.ID != "" && mf.ID != mod.ID {
		return nil, nil, nil, &PolicyDecisionError{Reason: PolicyDecisionInvalid, Err: fmt.Errorf(
			"policy invalid: manifest id %q disagrees with module id %q — refusing a mismatched manifest", mf.ID, mod.ID)}
	}
	policy = buildPolicy(mf)
	droppedCaps = policy.DropUnknownCapabilities()
	if enforcePrivileged && policy.Privileged && !privilegedApproved(mod.ID, privilegedAllow) {
		// The module REQUESTS privileged (all confinement off) but the operator
		// has not GRANTED it via privileged_module_ids. Refuse the attach
		// outright — running it unconfined on an unapproved request is exactly
		// the hole IMP-01a02f70-20b1 named. Fatal + loud: the attach loop marks
		// the pass unconverged, so the platform sees a convergence failure
		// rather than a module silently running with no confinement.
		return nil, nil, droppedCaps, &PolicyDecisionError{Reason: PolicyDecisionPrivilegedUnapproved, Err: fmt.Errorf(
			"module %s requests security.privileged=true (disables all on-node confinement) "+
				"but is not in the operator-approved privileged allowlist (privileged_module_ids); "+
				"refusing to attach it unconfined", mod.ID)}
	}
	if errs := policy.Validate(); len(errs) > 0 {
		return nil, nil, droppedCaps, &PolicyDecisionError{Reason: PolicyDecisionInvalid, Err: fmt.Errorf("policy invalid: %v", errs)}
	}
	// Per-service capabilities (IMP-caef5c00d63f), resolved BEFORE anything is
	// applied: a service asking for more than the module ceiling refuses the
	// whole attach, the same way an invalid policy does, rather than guessing
	// which of the two lists the author meant. Privileged modules take no
	// capability drop-ins at all, so they are not resolved.
	var unitCaps []security.UnitCapabilities
	if !policy.Privileged {
		var svcDropped []string
		unitCaps, svcDropped, err = capabilityWriter(mf, policy)
		// L4 (review round 7, MEDIUM): merged into the SAME droppedCaps this
		// function already returns for the module-wide ceiling (K5b) — one
		// OnError call site (applyModuleSecurityPolicy, below) covers both,
		// rather than a second, easily-forgotten diagnostic for the
		// per-service case. Appended even when err != nil: a version-skew
		// name and a genuine "outside the ceiling" violation on a DIFFERENT
		// name can both be true for the same manifest at once, and the
		// caller deserves to see the drop regardless of whether the error
		// also refuses the module.
		droppedCaps = append(droppedCaps, svcDropped...)
		if err != nil {
			return nil, nil, droppedCaps, &PolicyDecisionError{Reason: PolicyDecisionCapabilitiesInvalid, Err: fmt.Errorf("policy invalid: %w", err)}
		}
	}
	unitAllow = make(map[string][]string, len(unitCaps))
	for _, uc := range unitCaps {
		unitAllow[uc.Unit] = uc.Allow
	}
	return policy, unitAllow, droppedCaps, nil
}

// applyIdentityAndSudoers renders and applies /etc/passwd + /etc/group +
// /etc/shadow + /etc/gshadow and sudoers from manifests — the SAME
// render/apply RunOnce's own identity/sudoers block performs, factored out
// (S1, delta review on 5f61d389, HIGH) so upgradeModule can call it too,
// immediately before step 4's first restart (see that call site's own doc),
// and refuse to restart at all if it fails.
//
// Both writes are always ATTEMPTED regardless of the other's outcome — an
// identity failure does not skip the sudoers attempt — matching RunOnce's
// own pre-existing resilience exactly (a caller that only wants "did
// EITHER fail" gets that from the returned error; RunOnce itself ignores
// it, since its own behavior was always "log and continue" via the
// per-write OnError calls below, never a hard stop). stagePrefix
// distinguishes RunOnce's own OnError lines ("reconciler:") from
// upgradeModule's own pre-step-4 call, matching every other decision this
// file shares between the live and bump paths.
func (r *Reconciler) applyIdentityAndSudoers(manifests []*manifest.Manifest, stagePrefix string) error {
	// Doc (review round 11, requested alongside N3): precedence and its
	// accepted cost, stated explicitly rather than left implicit in
	// manifests' own construction order. Wherever a caller unions an OLD
	// manifest alongside a NEW one for the same module ID (RunOnce's own
	// touched-digest union, or upgradeModule's own old∪touched∪new render),
	// etcidentity.Collect/etcsudoers.CollectFromManifests both keep the
	// FIRST occurrence of a given name and only ever CONFLICT-REPORT (never
	// silently merge) a same-name entry that later disagrees on UID/GID —
	// so which manifest is ordered first decides which one's values win a
	// same-name collision. This is ACCEPTED regardless of ordering: either
	// resolution describes a digest that either already ran or is about to,
	// and the discrepancy is always surfaced via reconciler:identity_conflict
	// rather than silently applied. What this does NOT catch: two DIFFERENT
	// names colliding on the SAME UID/GID — Collect's own conflict detection
	// is keyed by name, not by id, so that case renders two passwd entries
	// sharing one UID with no warning at all. Also accepted here — a bump
	// that both renames a user's login name AND keeps its exact old numeric
	// id is exactly the shape a real "svc user rename" migration takes.
	//
	// The sudoers side of the SAME union is a temporary WIDENING for as
	// long as a bump stays pending (a grant either the old or the touched
	// side declares is honoured), WIDER than either digest alone would
	// grant on its own. Also accepted: sudoers scope creep for the
	// duration of an in-flight upgrade is a smaller risk than a
	// crash-restarting unit finding a sudo rule it needs missing. O8(c)
	// (review round 12): that duration is VISIBLE (PendingDigest + the
	// heartbeat's PendingModuleDigests stay set the entire time) but is
	// NOT bounded — a crash-looping settle failure retries under
	// backoffAllows' growing wait, and a revert that itself keeps failing
	// retries under the same backoff — either can hold this union open for
	// as long as the underlying failure persists. "Visible" is the actual
	// mitigation here, not "bounded".
	identitySet, conflicts := etcidentity.Collect(manifests)
	for _, c := range conflicts {
		r.cfg.OnError(stagePrefix+"identity_conflict",
			fmt.Errorf("%s %q kept=%d dropped=%d (source=%s)",
				c.Kind, c.Name, c.KeptValue, c.DroppedValue, c.SourceModule))
	}
	var firstErr error
	if err := applyIdentity(identitySet); err != nil {
		r.cfg.OnError(stagePrefix+"identity_write", err)
		firstErr = fmt.Errorf("identity: %w", err)
	}
	// Make the filesystem agree with the passwd we just rendered: managed
	// home dirs must be owned by the user etcidentity declared (uid/gid =
	// platform source of truth) and /home must stay traversable, else sshd
	// and any unprivileged service with HOME there break. Idempotent.
	reconcileHomeOwnership(identitySet, "", r.cfg.OnError)
	if err := applySudoers(etcsudoers.CollectFromManifests(manifests)); err != nil {
		r.cfg.OnError(stagePrefix+"sudoers_write", err)
		if firstErr == nil {
			firstErr = fmt.Errorf("sudoers: %w", err)
		}
	}
	return firstErr
}

// applyModuleSecurityPolicy is the EFFECTFUL half: builds/validates the
// decision (decideModuleSecurityPolicy), then actually applies it —
// Policy.Apply (MAC profile load: semodule -i / apparmor_parser -r, host
// mutation) and the REAL seccomp/capability/user-namespace drop-in writers
// (security_dropins.go's applyModuleSecurityDropIns), which overwrite the
// unit's LIVE drop-in files on disk. Returns the units (if any) whose
// drop-in write failed non-exempt, AND (W1, IMP-caef5c00d63f round W) the
// units whose drop-in bytes actually CHANGED — a live reconcile that only
// touches security drop-ins moves no unit BODY at all, so
// AttachServicesModeOpts' own anyWritten/RestartChanged tracking (which only
// sees unit-body writes) is blind to it; the caller threads changedUnits
// into the services attach so a confinement-only change still reaches a
// running unit instead of silently sitting on disk unapplied.
//
// Called ONLY from attachModule — the real (re)attach path.
func (r *Reconciler) applyModuleSecurityPolicy(ctx context.Context, mod mount.Module, mf *manifest.Manifest) (changedUnits, failedUnits []string, err error) {
	policy, unitAllow, err := r.decideSecurityPolicyForAttach(mod, mf)
	if err != nil {
		return nil, nil, err
	}
	if err := policy.Apply(ctx, r.cfg.MountRunner); err != nil {
		return nil, nil, fmt.Errorf("apply policy: %w", err)
	}
	// Seccomp + capability + user-namespace drop-ins, through the SAME
	// decision renderPivotUnits (compose.go) uses — applyModuleSecurityDropIns
	// (security_dropins.go) — so the live (this function) and boot/pivot-
	// compose paths can never independently drift on which drop-in failures
	// are exempt from failing closed. Operator decision (round 3,
	// IMP-caef5c00d63f phase 4): fail closed on BOTH paths identically —
	// never run a module unconfined, whether the confinement gap was
	// discovered at boot or on a live reconcile tick. Before this, a
	// drop-in write failure here was non-fatal: the caller went on to call
	// attachModuleServices, which WRITES the unit and STARTS it — unconfined,
	// because the drop-in never landed — while nothing distinguished that
	// attach from an ordinary successful one.
	return r.writeSecurityDropIns(mf, policy, unitAllow)
}

// decideSecurityPolicyForAttach wraps decideModuleSecurityPolicy with the
// live path's own fixed parameters (enforcePrivileged: true — unlike the
// pivot path's frozen-allowlist conditional, see decideModuleSecurityPolicy's
// own doc) plus the K5b (review round 6) droppedCaps warning, shared by
// applyModuleSecurityPolicy (the full attach path) and
// applyModuleSecurityDropInsOnly (X4, IMP-caef5c00d63f round X — the
// once-per-boot confinement recheck's own narrower drop-in-only path) so
// the two can never independently drift on the decision itself.
func (r *Reconciler) decideSecurityPolicyForAttach(mod mount.Module, mf *manifest.Manifest) (policy *security.Policy, unitAllow map[string][]string, err error) {
	policy, unitAllow, droppedCaps, err := decideModuleSecurityPolicy(mod, mf, r.privilegedAllow, true, attachCapabilityWrites)
	if len(droppedCaps) > 0 {
		// K5b (review round 6): a real warning, not silence — dropping is the
		// SAFE response to a version-skew capability name (narrower, never
		// wider), but a silently narrowed ceiling would hide a genuine
		// manifest typo just as cleanly as it hides a real skew name.
		r.cfg.OnError("reconciler:unknown_capability_dropped",
			fmt.Errorf("module %s: dropped unrecognized capability name(s) %v from its declared ceiling (this agent version does not know them) — narrowing, never widening, what the module is confined to", mod.ID, droppedCaps))
	}
	if err != nil {
		return nil, nil, err
	}
	return policy, unitAllow, nil
}

// writeSecurityDropIns runs the actual drop-in writers (security_dropins.go)
// for an already-decided policy — factored out of applyModuleSecurityPolicy
// so applyModuleSecurityDropInsOnly (X4) can share the exact same writer
// wiring without also running policy.Apply (MAC profile load/host mutation).
func (r *Reconciler) writeSecurityDropIns(mf *manifest.Manifest, policy *security.Policy, unitAllow map[string][]string) (changedUnits, failedUnits []string, err error) {
	changedUnits, failedUnits = applyModuleSecurityDropIns(mf.ID, mf, policy, unitAllow, r.privilegedAllow,
		securityDropInFuncs{
			userNamespace:                 security.WriteUserNamespaceDropIn,
			seccomp:                       security.WriteSeccompDropIn,
			capability:                    security.WriteCapabilityDropIn,
			removeSeccomp:                 security.RemoveSeccompDropIn,
			removeCapability:              security.RemoveCapabilityDropIn,
			removeLegacyAmbientCapability: security.RemoveLegacyAmbientCapabilityDropIn,
		},
		func(stage string, err error) { r.cfg.OnError("reconciler:"+stage, err) },
	)
	return changedUnits, failedUnits, nil
}

// applyModuleSecurityDropInsOnly (X4, IMP-caef5c00d63f round X, MEDIUM) is
// applyModuleSecurityPolicy's DROP-IN half only: decideSecurityPolicyForAttach
// (pure) + writeSecurityDropIns (the writers), deliberately WITHOUT
// policy.Apply (MAC profile load/host mutation) and without anything
// attachModule itself does (mountModuleArtifact's Pull/verify/cosign,
// hotReconcileIfNeeded's SyncModuleFiles). Used only by
// reconfirmConfinementIfNeeded (the once-per-boot-composition recheck,
// confinement_recheck.go): that path exists to catch a stale on-disk
// DROP-IN an older compose left behind for an otherwise-unchanged,
// already-attached module — nothing else about the module needs
// re-verifying or re-copying for that narrow purpose, and doing so anyway
// (the ORIGINAL W1-round design, which forced the module through the FULL
// attachModule) is exactly the unwanted cost/risk this function removes: a
// whole-blob re-pull/re-verify/cosign check on every boot regardless of
// whether the drop-in actually diverged, an unrelated MAC profile reload,
// and hotReconcileIfNeeded's file sync potentially overwriting content a
// LATER runtime write already rewrote.
func (r *Reconciler) applyModuleSecurityDropInsOnly(mod mount.Module, mf *manifest.Manifest) (changedUnits, failedUnits []string, err error) {
	policy, unitAllow, err := r.decideSecurityPolicyForAttach(mod, mf)
	if err != nil {
		return nil, nil, err
	}
	return r.writeSecurityDropIns(mf, policy, unitAllow)
}

// attachModule pulls + verifies + mounts a single module and applies its
// security policy. It deliberately does NOT start the module's units — that is
// attachModuleServices, which every caller must invoke separately once the
// module's FILES are on disk. See attachModuleServices for why the two halves
// are split.
//
// changedUnits (W1, IMP-caef5c00d63f round W) names every unit whose
// security drop-in bytes actually changed THIS pass (nil on any refusal
// path, and always nil for the fresh-attach case — nothing was running
// before to restart). The caller threads it into the matching
// attachModuleServices call so a confinement-only change (no unit body
// change at all) still reaches an already-running unit.
func (r *Reconciler) attachModule(ctx context.Context, mod mount.Module, mf *manifest.Manifest) (changedUnits []string, err error) {
	if err := r.mountModuleArtifact(ctx, mod); err != nil {
		return nil, err
	}

	// J3 (review round 5): record these units as ATTEMPTED this pass
	// regardless of what applyModuleSecurityPolicy returns below —
	// publishSecurityFailClosed carries forward a PREVIOUSLY published
	// refusal for any unit NOT in this set, so a module whose decision this
	// pass genuinely could not reach (mountModuleArtifact failed above, or a
	// manifest fetch failure upstream kept it out of this loop entirely)
	// must never be marked attempted — but one whose decision WAS reached
	// here, even a REFUSAL, is a fresh, current-tick answer and must
	// replace, not preserve, whatever was published before.
	r.securityPolicyAttemptedUnits = append(r.securityPolicyAttemptedUnits, mf.UnitNames()...)

	changedUnits, failedUnits, err := r.applyModuleSecurityPolicy(ctx, mod, mf)
	if err != nil {
		// K5a (review round 6): an unapproved privileged request, an invalid
		// policy, or a Policy.Apply (MAC profile load) failure is the SAME
		// kind of event as a drop-in write failure — applyModuleSecurityPolicy
		// refusing to let this module attach unconfined — so it gets the SAME
		// typed error, not a bare fmt.Errorf. No single unit is "the" failing
		// one here (the refusal happened before any per-unit drop-in was even
		// attempted), so Units names every unit the module owns.
		//
		// R6 (review round 14): record it too — before this, ONLY the
		// per-unit drop-in-write-failure branch below called
		// recordSecurityFailClosed, so an unapproved-privileged request, an
		// invalid policy, or a Policy.Apply failure never reached
		// SecurityFailClosedUnits()/the heartbeat's RuntimeSecurityFailClosedUnits
		// at all — despite being, per K5a's own doc, the SAME kind of event.
		r.recordSecurityFailClosed(mf.UnitNames())
		return nil, &SecurityFailClosedError{ModuleID: mod.ID, Units: mf.UnitNames(), Reason: err.Error()}
	}

	if len(failedUnits) > 0 {
		r.recordSecurityFailClosed(failedUnits)
		// DELIBERATELY NOT stopping a currently-running unit here (review
		// round 4 shipped that, round 5 both reviewers required removing it —
		// G1, CRITICAL). Two independent reasons, either alone sufficient:
		//
		//  1. UNRECOVERABLE ON A SELF-HOSTED NODE. ops-hub reconciles ITSELF —
		//     if the failing unit is rails or postgres, stopping it here
		//     takes down the control plane THIS RunOnce needs to keep
		//     working: the next tick's FetchAssignedModules call goes to the
		//     now-dead rails and returns before ever reaching attachModule
		//     again, so nothing on this node ever restarts the unit. The
		//     heartbeat and the sensor this fail-closed state feeds
		//     (SecurityFailClosedSensor) both report to that same dead rails.
		//     A node that cannot repair itself must never be the thing this
		//     code stops.
		//  2. IT ENFORCED SOMETHING SUCCESS DOESN'T. AttachServicesModeOpts
		//     (attachModuleServices, below) only restarts a unit whose BODY
		//     changed on this pass AND the node is not self-hosted
		//     (RestartChanged: !r.selfHosted()) — a security drop-in write
		//     succeeding does not itself trigger a restart or a
		//     daemon-reload; the running process keeps its OLD effective
		//     capabilities until something ELSE restarts it. Stopping the
		//     unit specifically when the write FAILS would have enforced a
		//     stricter guarantee ("the running process always reflects the
		//     latest drop-in") than a SUCCESSFUL write ever gives — the
		//     asymmetry is itself a defect, not an extra safety margin.
		//
		// What actually satisfies "never run a module unconfined" here:
		// refusing to (re)attach/start the module (this error return, which
		// the caller treats identically to an invalid-policy or
		// privileged-unapproved refusal — no attach stamp, no
		// attachModuleServices call) plus recording + alerting
		// (recordSecurityFailClosed above, surfaced by
		// SecurityFailClosedSensor). A unit that was NEVER running is
		// correctly kept that way; a unit that WAS already running keeps
		// running under whatever drop-in it already had — which is a state
		// the node was already in, the same posture hotReconcileIfNeeded's
		// scratch-budget refusal already accepts for file materialization.
		r.cfg.OnError("reconciler:security_dropin_fail_closed",
			fmt.Errorf("module %s: security drop-in write failed for unit(s) %v — refusing to (re)attach/start (fail closed, not unconfined)", mod.ID, failedUnits))
		// Returning an error here reuses the SAME refusal path attachModule
		// already has for an invalid policy or an unapproved privileged
		// request (above): the caller's noteUnconverged does not record this
		// module's attach stamp and does not call attachModuleServices, so a
		// first attach never starts the module's units at all, and a
		// re-attach's stamp stays stale — which re-queues the module into
		// toReattach on every later tick until the write succeeds.
		//
		// A typed *SecurityFailClosedError, not a bare fmt.Errorf (J2, review
		// round 5): AttachOne's caller (the `powernode-agent attach` CLI,
		// its own short-lived process — see AttachOne's doc comment) has no
		// other way to learn WHICH units refused and choose a distinct exit
		// code for it, once this function stops publishing into
		// SecurityFailClosedUnits() from that process (H1 was reverted
		// because that publish had no reader there).
		return nil, &SecurityFailClosedError{ModuleID: mod.ID, Units: failedUnits, Reason: "security drop-in write failed and was not exempt"}
	}

	// Every one of this module's security drop-ins just wrote successfully —
	// mark its units RECOVERED for the rest of this boot (G5), so
	// buildHeartbeat can stop reporting a stale boot-time pivot refusal for
	// any of them once the live path has proven it can write their
	// confinement correctly. Unconditional (not gated on whether any of
	// these units were ever pivot-refused): a no-op for a unit the pivot
	// breadcrumb never named, and exactly the signal buildHeartbeat needs
	// for one that was.
	r.recordSecurityFailClosedRecovered(mf.UnitNames())

	return changedUnits, nil
}

// attachModuleServices is the SECOND half of an attach: the systemd side.
//
// It is separate from attachModule because of an ordering invariant the two
// halves must satisfy and a single function could not: the module's FILES must
// be on disk before its units are (re)started. attachModule leaves the module
// mounted and its security policy applied — both prerequisites of the
// materialization — and the caller runs hotReconcileIfNeeded between the two.
// A caller that refuses the materialization must NOT call this.
//
// WHY. Until 2026-09-04 the service start lived at the end of attachModule, so
// it ran BEFORE anything materialized the new content. A materialization that
// was then refused (scratch budget) or that aborted mid-walk left systemd
// running the NEW unit definitions against the OLD or half-written tree — the
// update did not merely fail to apply, it applied wrong. Live: ops-hub deploy 4
// served hub-frontend v29's Sep-3 index.html over its new assets, and the
// v92/v93 backend strand is the same defect on a module that has units.
//
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
// attachStamp is the value the re-attach gate compares (IMP-01a05efa,
// IMP-f5c0afa7183a).
//
// THREE INPUTS, for three different failure modes:
//
//   - The RENDERED unit bodies (lifecycle.RenderedServicesHash), not the
//     manifest. The unit body is not a function of the manifest alone — the
//     root mode and the inverted dependency graph feed the renderer too — so a
//     corrected RENDERER shipped in a new agent binary left the old
//     manifest-hash stamp byte-identical, queued no module for re-attach, and
//     never replaced the stale unit on disk.
//
//   - The rendered SECURITY POLICY (security.RenderedPolicyHash), not the
//     manifest's security: block either. attachModule applies a module's
//     entire resolved Policy — capability/seccomp/user-namespace drop-ins AND
//     SELinux/AppArmor profile loads — and NONE of that is a function of
//     mf.Services, so it was invisible to the unit-body hash above by
//     construction. A manifest edit confined to security: (a capability
//     added, a profile swapped) left this stamp byte-identical, so the
//     change never reached an already-attached node until an unrelated
//     unit-body change or an agent-version bump forced a pass. Fixing this
//     the way IMP-01a05efa fixed the unit-body half — stamp the manifest's
//     security: block directly — would have repeated that exact defect one
//     layer over: RenderedPolicyHash stamps what the drop-in writers and MAC
//     loaders actually RENDER/RESOLVE, via the same render functions they
//     use to produce their bytes, for the identical reason
//     RenderedServicesHash stamps rendered unit bodies rather than manifest
//     content. See security.RenderedPolicyHash's own doc for the full
//     reasoning, including why it is scoped to the cloud-init hot-reconcile
//     path only — ComposeForPivot (boot / soft-recompose) rebuilds every
//     module's units and drop-ins from scratch on every invocation and has
//     no stamp to go stale.
//
//   - The AGENT VERSION, so a change in an input neither render path covers
//     still forces one pass. This is the belt to both rendered hashes'
//     braces: it re-attaches every module once per agent upgrade whether or
//     not rendering changed.
//
// Adding a second stamp segment does NOT add an incremental one-time cost of
// its own, and that is worth stating precisely rather than assuming a
// re-attach is cheap merely because the drop-in writers are small files.
// It is not: mountModuleArtifact's Puller.Pull, called at the start of every
// attachModule regardless of which stamp segment changed, streams the ENTIRE
// cached erofs blob through SHA-256 on its cache-hit path (oci.readDigest)
// before returning, then VerifyBlob runs on top of that — real, size-
// proportional work per module, not a bounded three-small-files-plus-
// daemon-reload cost. (WriteCapabilityDropIn / WriteSeccompDropIn /
// WriteUserNamespaceDropIn are themselves an unconditional tmp-write +
// rename with no existing-content comparison — not writeIfChanged the way
// the unit-body path is — but that is a small piece of a pass whose real
// cost lives in the pull/verify step above it, not in the drop-ins.)
//
// The reason this stamp change is still safe to ship is not "the extra pass
// is cheap" — it's that THIS FIX SHIPS INSIDE A NEW AGENT BINARY, which is
// necessarily a new AgentVersion, which was ALREADY the third stamp segment
// before this change existed. Shipping this fix therefore forces exactly one
// fleet-wide re-attach pass on THIS upgrade regardless of whether the
// security-policy segment is also new — the new segment adds no additional
// fleet-wide pass beyond the one an agent upgrade already causes every time.
// semodule -i / apparmor_parser -r (the SELinux/AppArmor re-application, when
// either profile is declared) are the standard idempotent-reload idiom those
// tools document for exactly this case, but that is UNVERIFIED against a
// real LSM host from this codebase, and currently unexercised on this fleet
// because no module declares selinux_profile/apparmor_profile — it is a
// precondition to verify before the first module does, not a closed
// question. See docs/ATTACH_STAMP_SECURITY_POLICY_SURVEY.md.
func (r *Reconciler) attachStamp(moduleID string, mf *manifest.Manifest) string {
	if mf == nil {
		return ""
	}
	return r.attachStampContent(moduleID, mf) + "|" + r.cfg.AgentVersion
}

// attachStampContent is attachStamp's own content-only half — services hash
// + policy hash, WITHOUT the trailing "|"+AgentVersion segment attachStamp
// itself appends. Q2 (review round 14, MEDIUM): O7's bootstrap guard (P6,
// review round 13) must compare manifest CONTENT, not a version-qualified
// stamp — on the very first tick after an agent binary upgrade, EVERY
// stored LastAttachedManifestHashes entry was computed under the OLD
// version string, so comparing full stamps disagrees with a freshly
// computed one even when the manifest's own content is byte-identical. A
// module bumped on that same tick never gets its bootstrap snapshot; from
// the NEXT tick the ID-keyed cache already reflects the new manifest, so
// the miss becomes permanent (the new∪new identity / 217-USER class P6
// itself exists to prevent). Exists as its own method, not merely inlined
// into attachStamp, so attachStamp's own semantics (and every OTHER caller
// of it) are unchanged.
func (r *Reconciler) attachStampContent(moduleID string, mf *manifest.Manifest) string {
	if mf == nil {
		return ""
	}
	policy := buildPolicy(mf)
	// L4 (review round 7, MEDIUM): drop unrecognized ceiling capability names
	// BEFORE resolving per-unit sets, exactly as decideModuleSecurityPolicy
	// (the real attach path) does — without this, a version-skew name in the
	// ceiling made THIS stamp's capability resolution fail (or resolve
	// against the raw, undropped ceiling) while the real attach path,
	// already narrowed, computed a DIFFERENT effective set — the two could
	// disagree about whether anything changed. The dropped names themselves
	// are not surfaced here (attachModule's own call, moments later for a
	// module this stamp says needs re-attaching, already warns once); this
	// call exists only to keep policy.Capabilities in agreement with what
	// the real attach will actually use.
	policy.DropUnknownCapabilities()
	// Per-unit RESOLVED capability sets (IMP-caef5c00d63f), so a change to one
	// service's own capabilities key moves the stamp. A resolution error is
	// ignored here on purpose: attachModule refuses that module loudly, and
	// the entries still carry the raw lists, so fixing the manifest moves the
	// stamp and retries the attach.
	unitCaps, _, _ := attachCapabilityWrites(mf, policy)
	return lifecycle.RenderedServicesHash(moduleID, mf.Services, pivotAwareRootMode()) +
		"|" + security.RenderedPolicyHashForUnits(policy, unitCaps)
}

// stampContentOnly drops a full attachStamp's trailing "|"+AgentVersion
// segment, leaving just its content half (services hash + policy hash) — Q2
// (review round 14): lets a STORED stamp (computed under whatever agent
// version was running at attach time, which this function does not need to
// know) be compared against a freshly computed attachStampContent without
// caring what that old version string was.
func stampContentOnly(fullStamp string) string {
	idx := strings.LastIndex(fullStamp, "|")
	if idx < 0 {
		return fullStamp
	}
	return fullStamp[:idx]
}

// confinementChanged (W1, IMP-caef5c00d63f round W) names every unit whose
// security drop-in the CALLER's own attachModule call just rewrote (nil for
// a fresh attach — nothing was running before). See attachModuleServicesOpts'
// own doc for how it changes the restart decision.
//
// Round Y (IMP-caef5c00d63f): void — X1's persisted pending-confinement set
// (mount.Module.PendingConfinementUnits, pendingConfinementUnitsFor/set/
// track/resolve/report, all deleted this round) is gone. A unit this node
// declines to restart (self-hosted, or detection Unknown) is no longer
// bookkept as "pending" at all: reconcileStaleConfinement (confinement_
// probe.go) RE-DERIVES staleness every tick straight from /proc, so there is
// nothing to carry forward and nothing that ever needs un-stamping to force
// a retry — see that file's own doc for why that closes N1 (a self-hosted
// node's pending set that could never clear) and N3 (the crash-window gap
// a persisted set could lose).
func (r *Reconciler) attachModuleServices(ctx context.Context, current *mount.State, mod mount.Module, mf *manifest.Manifest, confinementChanged []string) {
	// FENCED ON THE SELF-HOSTED NODE, for the same reason and by the same
	// invariant as filterUnsafeDetaches (selfhost.go): the services that
	// answer this node's own reconcile endpoint are the ones it would be
	// restarting, and a restart window there is self-inflicted on the one node
	// that cannot be told to recover. Milder than the detach incident — a
	// restarted service does come back — but the asymmetry is the same, so the
	// new body lands on disk and takes effect at the next recompose, which is
	// already the documented behaviour for composition changes.
	//
	// round 9: this fence is NOT universal — upgradeModule's own call
	// (attachModuleServicesOpts, below, with restartChanged forced true)
	// deliberately bypasses it for a version bump specifically (A2, review
	// round 9): a bump genuinely needs the new binary running, and the
	// detach-before-attach path this replaces ALSO restarted a self-hosted
	// node's own rails/postgres via its own stop+start cycle. Every OTHER
	// caller — an ordinary manifest-only reattach, a fresh attach — still
	// goes through this fenced path unchanged.
	//
	// round Y: restartPermitted() replaces !r.selfHosted() — Unknown
	// detection now withholds a restart too (N2), not just a confirmed Yes.
	results, err := r.attachModuleServicesOpts(ctx, mod, mf, r.restartPermitted(), false, confinementChanged)
	r.reportConfinementRestartOutcome(mod, confinementChanged, results, err)
}

// reportConfinementRestartOutcome (round Y) is attachModuleServices' own
// visibility half, replacing X1's reportPendingConfinement. Nothing here is
// bookkept as durably "pending" any more (see attachModuleServices' own
// doc) — a withheld restart is reported THIS TICK ONLY, on the same channel
// every other transient reconcile condition uses, and reconcileStaleConfinement
// re-reports it (or not) fresh on the next tick from /proc, never from
// anything this function wrote.
//
// A restart the agent itself ISSUED this pass but that FAILED is the one
// case that still goes through noteUnconverged: that is a genuine "we tried
// and failed" for a task consulting ConvergenceFailures() (apply_config,
// sync), and it cannot linger as bookkeeping because the next tick
// re-derives everything from scratch.
func (r *Reconciler) reportConfinementRestartOutcome(mod mount.Module, confinementChanged []string, results []lifecycle.AttachResult, err error) {
	if len(confinementChanged) == 0 {
		return
	}
	byUnit := make(map[string]lifecycle.AttachResult, len(results))
	for _, res := range results {
		byUnit[res.Unit] = res
	}
	for _, unit := range confinementChanged {
		res, ok := byUnit[unit]
		if ok && res.StepErr != nil {
			r.noteUnconverged("reconciler:confinement_restart_failed", mod.ID,
				fmt.Errorf("module %s: unit %s's security confinement changed and a restart was attempted but failed: %w", mod.ID, unit, res.StepErr))
			continue
		}
		if ok && res.ConfinementPendingRestart {
			r.cfg.OnError("reconciler:confinement_pending_restart",
				fmt.Errorf("module %s: unit %s's security confinement changed but this node is self-hosted (or restart is not positively confirmed safe) — reload applied, restart deliberately withheld (rule 1: never restart a service this node's own reconcile may depend on); schedule an operator restart or wait for the next recompose", mod.ID, unit))
		}
	}
	if err != nil {
		r.cfg.OnError("reconciler:confinement_apply", fmt.Errorf("module %s: applying confinement changes to %v: %w", mod.ID, confinementChanged, err))
	}
}

// attachModuleServicesOpts is attachModuleServices' parameterized core
// (round 9): the systemd half of an attach, with the RestartChanged
// decision taken as an explicit argument instead of always deriving it
// from selfHosted(). See attachModuleServices' own doc for why the fence
// exists and upgradeModule's own doc for why it bypasses it.
//
// forceRestartActive (M1, review round 9): upgradeModule's OWN restart
// mode, distinct from restartChanged — see lifecycle.AttachOptions.
// ForceRestartActive's doc for why a digest bump needs this rather than
// the ordinary RestartChanged decision. Every other caller passes false.
//
// Returns the per-unit []lifecycle.AttachResult alongside the error (N6,
// review round 11): upgradeModule needs to know EXACTLY which units were
// actually restarted onto the new binary — even on a partial failure, the
// units attempted before the failing one are still named here — so its own
// failure-path drop-in restore never re-applies the OLD policy under a unit
// that is already running the NEW process. Every other caller discards it.
//
// confinementChanged (W1, IMP-caef5c00d63f round W) names units whose
// security drop-in bytes actually changed THIS pass — a change that moves
// no unit BODY at all, so AttachServicesModeOpts' own writeIfChanged/
// anyWritten tracking (unit-body writes only) never sees it. Passing nil is
// always safe (matches every pre-W1 caller's behavior exactly) — every
// caller that ALREADY force-restarts unconditionally (forceRestartActive,
// upgradeModule's own step 4 and the N2 revert-forced-restart branch) passes
// nil deliberately: ForceRestartActive already restarts every active unit
// of this module regardless of what changed, so consulting this set there
// would only risk a confusing SECOND restart decision for units already
// covered, never a genuinely different outcome.
func (r *Reconciler) attachModuleServicesOpts(ctx context.Context, mod mount.Module, mf *manifest.Manifest, restartChanged, forceRestartActive bool, confinementChanged []string) ([]lifecycle.AttachResult, error) {
	if len(mf.Services) == 0 {
		return nil, nil
	}
	// Boot-model-aware: the reconcile loop runs post-pivot on a hub
	// (module union IS /, render native) AND on cloud_init hosts (guest
	// OS is /, chroot into /sysroot). PivotAwareRootMode picks by whether
	// /persist reads as a distinct mount. A chroot-rendered unit on a
	// pivoted host stamps RootDirectory=/sysroot — which switch_root
	// already consumed — so the service never starts (the hub enrolls but
	// runs no app modules).
	//
	// RestartChanged (IMP-01a05efa): a REWRITTEN unit body does not reach the
	// running process by itself — `systemctl start` is a no-op on an active
	// unit — so before this a corrected renderer replaced the file and the
	// service kept running the old definition until something else restarted
	// it. AttachServicesModeOpts restarts a unit only when its body actually
	// changed on this pass AND it is currently active.
	opts := lifecycle.AttachOptions{RestartChanged: restartChanged, ForceRestartActive: forceRestartActive, ConfinementChangedUnits: confinementChanged}
	results, err := lifecycle.AttachServicesModeOpts(ctx, r.cfg.MountRunner, mod.ID, mf.Services, lifecycle.PivotAwareRootMode(), opts)
	if err != nil {
		r.cfg.OnError("reconciler:attach_services",
			fmt.Errorf("module %s: %w", mod.ID, err))
		return results, err
	}
	return results, nil
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
//   - Scratch pre-flight (escalateIfHotRungTooSmall): the module's whole
//     remaining diff is priced against the scratch's usable budget BEFORE
//     anything is copied. A module that cannot fit is refused here, with
//     nothing written, and routed to the soft-recompose rung — copying part
//     of it first is what turns one abort into a permanent ratchet.
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
// reconciler does resolves them. Only the scratch-budget arms are genuinely
// transient — the space may exist next time — and that covers BOTH the mid-walk
// abort and the pre-flight escalation. The escalation stays in toReattach on
// purpose even though the reconciler alone will not resolve it: unlike
// reboot_required, its every-tick cost is a walk that stops at the first blown
// budget, and staying queued is what keeps the module listed as unmaterialized
// so the heartbeat does not resume claiming the unwritten version is running.
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
	opts := SyncOptions{
		HigherLayers: r.higherPriorityLayerDirs(desired, mod.ID),
		MinFreeBytes: r.scratchMinFreeBytes(),
	}
	if escalated := r.escalateIfHotRungTooSmall(mod, srcDir, dstRoot, opts); escalated {
		return true
	}
	res, err := SyncModuleFiles(srcDir, dstRoot, opts)
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

// escalateIfHotRungTooSmall is the PRE-FLIGHT: it asks whether this module's
// whole remaining diff fits the live root's scratch BEFORE a single byte is
// copied, and when it does not, refuses the hot rung outright and says so.
//
// WHY, IN ONE SENTENCE: a mid-walk budget abort is a RATCHET. The per-file
// guard copies until one file would breach the floor, and everything it wrote
// stays (correctly — it is winner content, and the module keeps serving its old
// files intact because hotReconcileIfNeeded returns before the prune). But those
// bytes are exactly the free space the retry needs, so the next tick has LESS
// room than the one that just failed and refuses the first non-identical file it
// reaches regardless of size. Live on ops-hub 2026-09-04: a 195-byte
// BUILD_INFO.json refused at 34 MB free against a 64 MiB floor. Every later tick
// made exactly zero progress until an operator deleted 54 MB of cache by hand.
// Declining the copy ENTIRELY keeps that space, and keeps the module coherently
// on its old version instead of split at an arbitrary alphabetical boundary with
// its units already restarted against the mixture.
//
// WHAT IT ESCALATES TO. The middle rung of the recompose ladder:
// `powernode-agent soft-recompose --execute` composes at /run/nextroot against
// its OWN scratch tmpfs (mount.NextrootLayout — never shares upper/work with the
// live root), so the same diff costs zero bytes of the live upper and a module
// the hot rung can never take lands there. That pointer already existed in the
// abort's error string; what did not exist was any code that decided a module
// belongs on that rung rather than retrying this one forever. This is a SIGNAL,
// deliberately not an invocation: soft-reboot takes userspace down, which is an
// operator's decision (and on a self-hosted control plane, a decision about the
// machine issuing it).
//
// The floor is NOT raised to make this fit, and the ceiling is not either. The
// scratch is 512 MiB (mount.DefaultScratchSize, no caller sets
// Overlay.ScratchSize) and the upper never reclaims, so a 1 GiB ceiling buys
// about one extra deploy per boot before failing identically — at the cost of
// doubling tmpfs RAM on every node in the fleet for what is a hub-shaped
// problem. See f72ede5a's message for the arithmetic.
//
// Returns escalated=true when the caller must skip the sync (and the prune —
// same reasoning as the abort arm: whiteouts are upperdir entries too) and
// report retryNeeded. Retry stays TRUE on purpose: it is what keeps the module
// in toReattach, which is what keeps it in State.UnmaterializedModules, which is
// what keeps the heartbeat from claiming the unwritten version is running
// (IMP-bc1b0495352d / f72ede5a). A module that escalates re-runs this pre-flight
// every tick — cheap, because the walk stops as soon as the budget is blown —
// and converges the moment the space appears or the operator takes the next rung.
func (r *Reconciler) escalateIfHotRungTooSmall(mod mount.Module, srcDir, dstRoot string, opts SyncOptions) bool {
	floor := opts.MinFreeBytes
	if floor == 0 {
		return false // guard disabled: no budget to pre-flight against
	}
	free, ferr := freeBytesAt(dstRoot)
	if ferr != nil {
		// Fail open, exactly as the per-file guard does: a probe failure must
		// not block a materialization that may well fit, and the guard is
		// still armed underneath.
		return false
	}
	var budget uint64
	if free > floor {
		budget = free - floor
	}
	plan, perr := PlanScratchBudget(srcDir, dstRoot, budget, opts)
	if perr != nil {
		// Advisory: PlanScratchBudget counts an uncomparable entry as needing
		// its full size, so these can only have made the plan more
		// conservative, and the Fits verdict rests on measured bytes alone.
		// Surfaced through OnError rather than noteUnconverged — an unreadable
		// entry is not by itself a failure to converge, and the sync below
		// reports it again if we do proceed.
		r.cfg.OnError("reconciler:hot_preflight", fmt.Errorf("module %s: %w", mod.ID, perr))
	}
	if plan.Fits {
		return false
	}
	r.noteUnconverged("reconciler:recompose_escalate", mod.ID,
		fmt.Errorf("module %s: at least %d bytes of new content against %d usable (%d free, %d-byte floor) — "+
			"declining the live materialization ENTIRELY rather than copying part of it, because a partial copy "+
			"consumes exactly the space a retry needs and every later tick then refuses. This module needs the "+
			"next rung: `powernode-agent soft-recompose --execute` composes at /run/nextroot with its own scratch, "+
			"where this diff costs zero bytes of the live root's upper",
			mod.ID, plan.RequiredBytes, budget, free, floor))
	return true
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
	//
	// NOTE (round 9): round 7 (L6b) found that this is actively wrong for a
	// version bump's OLD digest specifically — `manifests[mod.ID]` holds
	// THIS TICK'S manifest for the NEW digest, not the one mod.Digest was
	// actually running under, so a renamed service's old unit was never
	// stopped. That fix (a digest-keyed attached-snapshot lookup) is
	// removed here as part of the round-9 in-place-upgrade redesign:
	// detachModule now only ever runs for a genuine REMOVAL (no same-ID
	// successor), where this ambiguity cannot arise. The upgrade path
	// (which replaces detach-then-attach for a bump) resolves old unit
	// names from its own persisted Units list instead of going through
	// detachModule at all.
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
	// O7 (review round 12): this is a genuine removal (no same-ID
	// successor reaches this function — an upgrade or a revert never calls
	// detachModule at all), so the N3 store has nothing left to answer for
	// ANY digest of this module ID. Best-effort: a failure here leaves a
	// harmless orphaned file, not a correctness problem.
	if err := manifest.RemoveModuleSnapshots(r.cfg.ManifestRoot, mod.ID); err != nil {
		r.cfg.OnError("reconciler:upgrade_snapshot_gc", fmt.Errorf("module %s: %w", mod.ID, err))
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
// Fails CLOSED. If the root mode cannot be determined, the mount table cannot
// be read, or the union cannot be parsed, the answer is "would strip" — see
// the asymmetry argument at the call site.
func (r *Reconciler) unmountWouldStripLiveRoot(mod mount.Module) (bool, string) {
	// The error-reporting probe, not pivotAwareRootMode: that one reads a
	// failed statfs("/") as chroot, which would skip the live-union check and
	// unmount unguarded (IMP-1023e79cc82d).
	mode, err := pivotAwareRootModeChecked()
	if err != nil {
		return true, fmt.Sprintf("cannot determine root mode (%v); refusing to risk stripping the running root", err)
	}
	if mode != lifecycle.RootModeNative {
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

// SecurityFailClosedUnits returns the units the LIVE (cloud-init/pivot-
// reconcile) attach path currently REFUSES to (re)attach/start because a
// non-exempt security drop-in write failed — not necessarily stopped; an
// already-running re-attach target keeps running under its previous
// confinement (round 5, G1). nil/empty means none — read by buildHeartbeat
// into HeartbeatPayload.RuntimeSecurityFailClosedUnits.
func (r *Reconciler) SecurityFailClosedUnits() []string {
	if p := r.securityFailClosedUnits.Load(); p != nil {
		return *p
	}
	return nil
}

// recordSecurityFailClosed merges units into securityFailClosedPending,
// deduped. Called only from attachModule, whose every caller (RunOnce,
// AttachOne) holds r.mu for its entire body, so only one of them ever runs
// at a time and this plain (non-atomic) field needs no lock of its own — it
// is never read from any other goroutine. See securityFailClosedUnits'
// own doc for why the PUBLISHED value is atomic and updated separately
// (publishSecurityFailClosed), not here.
func (r *Reconciler) recordSecurityFailClosed(units []string) {
	if len(units) == 0 {
		return
	}
	seen := make(map[string]bool, len(r.securityFailClosedPending)+len(units))
	merged := make([]string, 0, len(r.securityFailClosedPending)+len(units))
	for _, u := range r.securityFailClosedPending {
		if !seen[u] {
			seen[u] = true
			merged = append(merged, u)
		}
	}
	for _, u := range units {
		if !seen[u] {
			seen[u] = true
			merged = append(merged, u)
		}
	}
	r.securityFailClosedPending = merged
}

// resetSecurityFailClosed clears the PENDING (not yet published) set, and
// the ATTEMPTED set (J3) alongside it, at the top of a fresh RunOnce pass —
// same reasoning as composeFailed.Store(false): both must describe the pass
// that just ran, never an older one, so a module that fixed its drop-in this
// tick drops off rather than staying flagged forever. Deliberately does NOT
// touch the published atomic value — see publishSecurityFailClosed and
// securityFailClosedUnits' own doc (G4).
func (r *Reconciler) resetSecurityFailClosed() {
	r.securityFailClosedPending = nil
	r.securityPolicyAttemptedUnits = nil
}

// publishSecurityFailClosed swaps the PUBLISHED atomic value over to
// whatever this pass accumulated, in ONE Store call. Called once, after
// RunOnce's attach/reattach loops finish, so a concurrent buildHeartbeat call
// reading SecurityFailClosedUnits mid-pass sees the PREVIOUS pass's complete
// result right up until this pass's own complete result replaces it — never
// an empty value manufactured by resetting before this pass has finished
// finding its own failures (G4: that gap would read as "recovered" to
// SecurityFailClosedSensor, clearing a real alarm, then re-raise it once the
// pass finishes).
//
// RunOnce OWNS THE WHOLE SET and is the ONLY caller. AttachOne (a single
// hot-add) does NOT publish at all: it runs inside the `powernode-agent
// attach` CLI's own short-lived process (see AttachOne's doc comment), which
// has no daemon-side reader for this Reconciler instance's atomic pointer to
// reach. An H1 (review round 5) draft published here from AttachOne too,
// reasoning by analogy with RunOnce; J2 (the replacement review) reverted it
// as dead code in production — see SecurityFailClosedError, which is
// AttachOne's actual signal to its CLI caller.
//
// NOT a bare full replace (J3, review round 5 REPLACEMENT review): a
// PREVIOUSLY published unit whose module this pass never reached the
// security-policy decision for — a manifest fetch failure, a no-digest
// module, a blob pull failure ahead of the drop-in step, any of the
// partial-view cases RunOnce's own manifest-fetch loop already names — is
// carried forward rather than dropped. Before this, a partial-view tick
// silently cleared that module's refusal (it never appeared in
// securityFailClosedPending, which only the units THIS pass actually decided
// go into), reading as "recovered" to SecurityFailClosedSensor for a module
// whose confinement status this pass learned NOTHING new about — then the
// alarm re-raised on the next tick that could reach it, flapping. A unit
// this pass DID reach the decision for (securityPolicyAttemptedUnits, set by
// applyModuleSecurityPolicy regardless of outcome) always uses THIS pass's
// fresh answer, never a stale one — carry-forward applies ONLY to units this
// pass could not even attempt.
//
// relevantUnits (K4, review round 6) bounds that carry-forward further: a
// unit is only EVER carried forward if it also belongs to a module this
// tick still considers relevant (desired, manifestFetchFailed, or retained —
// see RunOnce's own construction of this set). Without this bound, a module
// that is GENUINELY UNASSIGNED (removed from the platform's list entirely —
// a clean fetch that simply excludes it, never a fetch failure) can NEVER
// become "attempted" again — nothing will ever call
// applyModuleSecurityPolicy for a module RunOnce no longer even iterates —
// so J3's original unbounded carry-forward would republish that stale
// refusal FOREVER, with no tick ever able to clear it. A unit whose module
// vanished (not in relevantUnits) is dropped here, same as one that was
// actively attempted and found clean.
//
// R6 (review round 14): ALSO persists the merged result into current's own
// SecurityFailClosedUnits field and saves state.json — purely so
// NewReconciler can seed the in-memory atomic on the NEXT process start (see
// that field's own doc on mount.State). current may be nil (AttachOne's own
// SecurityFailClosedError path never reaches this function at all, per this
// function's own doc, but a defensive nil check costs nothing).
func (r *Reconciler) publishSecurityFailClosed(current *mount.State, relevantUnits map[string]bool) {
	attempted := make(map[string]bool, len(r.securityPolicyAttemptedUnits))
	for _, u := range r.securityPolicyAttemptedUnits {
		attempted[u] = true
	}
	// K6 (review round 6): deduped defensively, not just by construction —
	// every current caller pairs recordSecurityFailClosed with marking the
	// same units attempted (so a unit named in carry-forward and pending at
	// once should never actually happen today), but the PUBLISHED result
	// naming a unit twice is a real defect regardless of whether today's
	// callers happen to avoid it, and `seen` costs nothing to keep it true
	// unconditionally.
	seen := make(map[string]bool, len(r.securityFailClosedPending))
	merged := make([]string, 0, len(r.securityFailClosedPending))
	for _, u := range r.SecurityFailClosedUnits() {
		if !attempted[u] && relevantUnits[u] && !seen[u] {
			seen[u] = true
			merged = append(merged, u) // not reached this pass, but still relevant — carry forward
		}
	}
	for _, u := range r.securityFailClosedPending {
		if !seen[u] {
			seen[u] = true
			merged = append(merged, u)
		}
	}
	r.securityFailClosedUnits.Store(&merged)

	if current != nil {
		current.SecurityFailClosedUnits = merged
		if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
			r.cfg.OnError("reconciler:security_fail_closed_persist", fmt.Errorf("could not persist the published fail-closed set: %w", err))
		}
	}
}

// SecurityFailClosedRecovered returns the units whose live security drop-in
// write has succeeded at least once this boot. nil/empty means none — read
// by buildHeartbeat to suppress a stale boot-time pivot refusal (G5).
func (r *Reconciler) SecurityFailClosedRecovered() map[string]bool {
	if p := r.securityFailClosedRecovered.Load(); p != nil {
		return *p
	}
	return nil
}

// recordSecurityFailClosedRecovered merges units into the atomically-
// published recovered set. Called only from attachModule on a FULLY
// successful attach (every one of the module's security drop-ins wrote); its
// callers (RunOnce, AttachOne) hold r.mu for their entire body, so only one
// ever writes it at a time — the load-merge-store needs no lock of its own
// beyond what atomic.Pointer already gives concurrent readers.
func (r *Reconciler) recordSecurityFailClosedRecovered(units []string) {
	if len(units) == 0 {
		return
	}
	existing := r.SecurityFailClosedRecovered()
	merged := make(map[string]bool, len(existing)+len(units))
	for u := range existing {
		merged[u] = true
	}
	for _, u := range units {
		merged[u] = true
	}
	r.securityFailClosedRecovered.Store(&merged)
}

// AttachOne pulls + verifies + mounts a single module without
// running a full reconcile cycle. Used by the `attach` CLI for
// operator-driven hot-add of a debug module. Idempotent: if the
// module is already attached at the same digest, returns ok with
// status=already_attached.
func (r *Reconciler) AttachOne(ctx context.Context, moduleID string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	// M4 fix (a) (review round 9, MEDIUM, hard invariant): snapshot whatever
	// manifest is CURRENTLY cached on disk for this module BEFORE the
	// LoadOrFetch call below can overwrite that cache with fresh content —
	// the SAME ordering RunOnce's own previousManifests capture uses, and
	// for the same reason: if this call turns out to be a digest CHANGE
	// (below), the upgradeModule path this routes through needs a manifest
	// describing the OLD digest, and this is the only remaining source of
	// one after the fetch below runs.
	oldMfSnapshot, _ := manifest.LoadFromDisk(r.cfg.ManifestRoot, moduleID)

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

	if current.LastAttachedManifestHashes == nil {
		current.LastAttachedManifestHashes = map[string]string{}
	}

	var existing *mount.Module
	for i, m := range current.AttachedModules {
		if m.ID == moduleID {
			if m.Digest == mf.Digest {
				return "already_attached", nil
			}
			existing = &current.AttachedModules[i]
			break
		}
	}

	mod := mount.Module{ID: moduleID, Digest: mf.Digest, Priority: mf.EffectivePriority, FsverityRoot: mf.FsverityRootHash, CosignBundleB64: mf.CosignBundleB64}

	// M4 fix (a): a module already attached at a DIFFERENT digest is a
	// version bump, not a fresh attach — route it through upgradeModule
	// (mount new, apply new policy, force-restart, delta-stop departing
	// units, unmount old, REPLACE the state entry) exactly as RunOnce's own
	// bump handling does. The bug this replaces: appending a second
	// state.json entry for the SAME ID at a different digest, which the
	// NEXT ordinary RunOnce tick's have/want-by-digest diff reads as the
	// stale entry being a genuine REMOVAL (see M4 fix (b) in RunOnce for
	// the partition-level backstop) — stopping the very unit this call just
	// started.
	if existing != nil {
		// T1 (final review on f3339424, HIGH): AttachOne runs entirely
		// outside RunOnce's own render, so it never re-renders identity —
		// upgradeModule's own pre-step-4 call reads r.tickIdentityManifests
		// (RunOnce's own field, meant for a RunOnce-driven bump), which
		// would otherwise sit stale from whatever RunOnce pass last set it,
		// or nil/zero on an agent that has never run one yet. Rebuild the
		// full set here from every currently attached module's own
		// snapshot — this entry (existing) included, giving its OWN old
		// side exactly like RunOnce's own bumpOldSide does — refusing
		// before step 4 if any of them can't be resolved (never render a
		// partial set; same rule as reconciler:identity_render_skipped).
		//
		// U4 (final delta review, LOW): this rebuild is still NARROWER than
		// RunOnce's own render in two ways RunOnce's own resolveRenderCandidates
		// (+ bumpOldSide) covers and this simpler loop does not:
		//   1. A "breadcrumb-only" module — genuinely boot-composed but for
		//      any reason absent from current.AttachedModules right now —
		//      never contributes here at all, where RunOnce's own render
		//      would still include it via the breadcrumb fallback.
		//   2. PendingTouchedDigests for an OTHER attached module mid an
		//      abandoned/reverting episode names content genuinely still
		//      running on some unit — RunOnce's own bumpOldSide unions it
		//      in; this loop only ever reads am.Digest (the stable one).
		// Fix, picking the SMALLER of the two options team-lead offered:
		// reusing resolveRenderCandidates wholesale here would mean
		// replicating RunOnce's OWN fresh-fetch-every-desired-module step
		// (manifestFetchFailed, retained, desiredForLayers — none of which
		// AttachOne computes at all, being a single-module CLI command) for
		// a rare, operator-invoked path. Instead: (2) is closed directly
		// (a cheap, local per-module union, mirroring bumpOldSide's own
		// shape); (1) is closed by REFUSING outright — before any render is
		// even attempted — whenever the CURRENT boot's own breadcrumb names
		// a data-bearing module current.AttachedModules doesn't have, since
		// there is no cheap way for this path to independently reconstruct
		// that module's own identity contribution the way RunOnce's fresh
		// manifest-fetch loop can.
		if _, _, breadcrumbDataIDs := loadBreadcrumbManifests(); len(breadcrumbDataIDs) > 0 {
			attachedIDs := make(map[string]bool, len(current.AttachedModules))
			for _, am := range current.AttachedModules {
				attachedIDs[am.ID] = true
			}
			var missing []string
			for id := range breadcrumbDataIDs {
				if !attachedIDs[id] {
					missing = append(missing, id)
				}
			}
			if len(missing) > 0 {
				sort.Strings(missing)
				return "", fmt.Errorf("AttachOne(%s): this boot's own breadcrumb names data-bearing module(s) %v not present in current.AttachedModules — refusing rather than rebuild this tick's identity set from a view known to be incomplete", moduleID, missing)
			}
		}
		var tickManifests []*manifest.Manifest
		var unresolved []string
		for _, am := range current.AttachedModules {
			snap, err := manifest.LoadAttachedSnapshot(r.cfg.ManifestRoot, am.ID, am.Digest)
			if err != nil || snap == nil {
				unresolved = append(unresolved, am.ID)
				continue
			}
			tickManifests = append(tickManifests, snap)
			// U4: union in every digest this OTHER module's own episode
			// already touched, same as RunOnce's own bumpOldSide.
			for _, digest := range am.PendingTouchedDigests {
				if digest == am.Digest {
					continue // already covered above
				}
				if tsnap, terr := manifest.LoadAttachedSnapshot(r.cfg.ManifestRoot, am.ID, digest); terr == nil && tsnap != nil {
					tickManifests = append(tickManifests, tsnap)
				}
			}
		}
		if len(unresolved) > 0 {
			sort.Strings(unresolved)
			r.cfg.OnError("reconciler:identity_render_skipped", fmt.Errorf(
				"AttachOne(%s): could not resolve %d currently attached module(s)' manifest(s) [%s]; refusing this upgrade's own pre-step-4 identity render rather than render a view known to be missing a real module",
				moduleID, len(unresolved), strings.Join(unresolved, ", ")))
			r.tickIdentityManifests = nil
			r.tickIdentityRenderSkipped = true
		} else {
			r.tickIdentityManifests = tickManifests
			r.tickIdentityRenderSkipped = false
		}
		u := moduleUpgrade{old: *existing, new: mod}
		r.upgradeModule(ctx, current, u, mf, oldMfSnapshot, nil, mount.ModuleStack{}, false)
		if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
			return "", fmt.Errorf("save state: %w", err)
		}
		for _, m := range current.AttachedModules {
			if m.ID == moduleID && m.Digest == mf.Digest {
				return "attached", nil
			}
		}
		return "", fmt.Errorf("module %s: upgrade to digest %s did not commit — see the reconciler's own error log for the refusal", moduleID, mf.Digest)
	}
	// H1 (review round 5) bracketed this call with resetSecurityFailClosed +
	// publishSecurityFailClosedForModule, reasoning that a refusal here
	// needed to reach SecurityFailClosedUnits(). REVERTED (J2, the
	// replacement review): AttachOne runs inside the `powernode-agent
	// attach` CLI's own process (see this function's doc comment) — a
	// short-lived process that BuildReconciler constructs fresh and that
	// exits right after this call returns. Publishing into THIS
	// Reconciler's in-memory atomic pointer has no reader: the long-running
	// daemon that actually serves buildHeartbeat/SecurityFailClosedSensor is
	// a SEPARATE process with its OWN Reconciler and its OWN atomic pointer.
	// H1's publish call was therefore dead code in production — real only
	// inside a test that (like production never does) shares one Reconciler
	// instance across the CLI-shaped call and the read. The durable signal
	// for an operator running this CLI command is its own output and exit
	// code — see SecurityFailClosedError and RunAttach (attach_cmd.go).
	changedUnits, attachErr := r.attachModule(ctx, mod, mf)
	if attachErr != nil {
		return "", attachErr
	}
	// X2 (IMP-caef5c00d63f round X, MEDIUM): append to current.AttachedModules
	// BEFORE attachModuleServices — its own X1 pending-confinement bookkeeping
	// looks the module up by ID in this slice, and threading changedUnits
	// (not nil) matters here for the same reason it matters in RunOnce's own
	// fresh-attach loop: a module can already be running (e.g. a pivot
	// node's own boot compose started it) with drop-ins this call's
	// attachModule just rewrote.
	mod.Units = mf.UnitNames()
	current.AttachedModules = append(current.AttachedModules, mod)
	// Unconditional, unlike the two reconcile loops: this path never runs
	// hotReconcileIfNeeded, so there is no materialization verdict to honour
	// and nothing to gate on. The operator asked for a single hot-add and the
	// CLI promises "mount + start units" — returning attach_status="attached"
	// with no unit would be a false success.
	r.attachModuleServices(ctx, current, mod, mf, changedUnits)

	// T1 (final review on f3339424): persist THIS digest's manifest content,
	// same as RunOnce's own attach loop and upgradeModule's own step 7 —
	// without this, a LATER AttachOne call upgrading this same module could
	// never resolve ITS OWN old side via LoadAttachedSnapshot, and the
	// tick-scoped identity rebuild above would refuse every subsequent
	// AttachOne upgrade of a module that was ever first attached THIS way.
	if err := manifest.SaveAttachedSnapshot(r.cfg.ManifestRoot, mod.ID, mod.Digest, mf); err != nil {
		r.cfg.OnError("reconciler:attached_snapshot_save", fmt.Errorf("module %s digest %s: %w", mod.ID, mod.Digest, err))
	}
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
	Fsverity       verify.DigestVerifier
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
// background-loop graceful-degradation. ALWAYS sets SkipEgress: the
// long-running service is the only process with live SDWAN extras, and a
// CLI-triggered `update`/`sync`/`attach`/`detach` rebuilding the shared
// node-wide nft chain without them would silently drop the WireGuard
// tunnel until the service's own next tick — see SkipEgress's own doc.
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
		SkipEgress:     true,
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
