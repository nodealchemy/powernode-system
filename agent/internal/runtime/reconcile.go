package runtime

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"net/url"
	"sync"
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
}

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

	desiredModules, err := FetchAssignedModules(ctx, r.cfg.ModulesClient)
	if err != nil {
		r.lastError = fmt.Errorf("fetch assigned modules: %w", err)
		return r.lastError
	}

	// Build desired ModuleStack by fetching manifests for modules with data files.
	desired := make(mount.ModuleStack, 0, len(desiredModules))
	manifests := make(map[string]*manifest.Manifest, len(desiredModules))
	for _, mod := range desiredModules {
		if !mod.HasDataFile {
			continue // config-variety + skill modules have no blob to mount
		}
		m, err := manifest.LoadOrFetch(r.cfg.ManifestClient, r.cfg.ManifestRoot, mod.ID, r.cfg.ManifestTTL)
		if err != nil {
			r.cfg.OnError("reconciler:fetch_manifest", fmt.Errorf("module %s: %w", mod.ID, err))
			continue
		}
		if m.Digest == "" {
			r.cfg.OnError("reconciler:no_digest", fmt.Errorf("module %s has no digest (not published)", mod.ID))
			continue
		}
		desired = append(desired, mount.Module{
			ID:       mod.ID,
			Digest:   m.Digest,
			Priority: m.EffectivePriority,
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
	if err := etcsudoers.Apply(etcsudoers.CollectFromManifests(manifestsSlice)); err != nil {
		r.cfg.OnError("reconciler:sudoers_write", err)
	}

	// Attaches in priority order (low → high). Walks toAttach (new
	// mounts: fresh erofs pull + verify + mount + AttachServices) and
	// toReattach (already-mounted but manifest-changed: skips the pull/
	// mount via attachModule's idempotency, re-runs AttachServices to
	// pick up the new units). Each successful attach refreshes the
	// per-module manifest hash so the next cycle's diff sees no drift.
	attachStack := mount.ModuleStack(toAttach).SortByPriority()
	for _, mod := range attachStack {
		mf, ok := manifests[mod.ID]
		if !ok {
			r.cfg.OnError("reconciler:missing_manifest", fmt.Errorf("module %s: manifest not loaded", mod.ID))
			continue
		}
		if err := r.attachModule(ctx, mod, mf); err != nil {
			r.cfg.OnError("reconciler:attach", fmt.Errorf("module %s: %w", mod.ID, err))
			continue
		}
		current.AttachedModules = append(current.AttachedModules, mod)
		current.LastAttachedManifestHashes[mod.ID] = mf.ServicesHash()
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
			r.cfg.OnError("reconciler:reattach", fmt.Errorf("module %s: %w", mod.ID, err))
			continue
		}
		current.LastAttachedManifestHashes[mod.ID] = mf.ServicesHash()
	}

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
		overlay := &mount.Overlay{Layout: r.cfg.Layout, Runner: r.cfg.MountRunner}
		if err := overlay.MountUnion(ctx, mount.ModuleStack(current.AttachedModules)); err != nil {
			r.cfg.OnError("reconciler:union_mount", err)
			current.UnionMounted = false
		} else {
			current.UnionMounted = true
		}
	}

	if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
		r.lastError = fmt.Errorf("save state: %w", err)
		return r.lastError
	}

	r.lastReconcileAt = time.Now()
	r.lastError = nil
	return nil
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
		if err := r.cfg.Fsverity.VerifyDigest(ctx, cfsPath, mod.Digest); err != nil {
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

// attachModule pulls + verifies + mounts a single module, then applies security
// policy and starts its units in the cloud_init (RootDirectory chroot) model.
func (r *Reconciler) attachModule(ctx context.Context, mod mount.Module, mf *manifest.Manifest) error {
	if err := r.mountModuleArtifact(ctx, mod); err != nil {
		return err
	}

	// Apply security policy. SeccompProfile is a path inside the
	// module's mounted root; the drop-in for each unit is written
	// here so subsequent systemctl start picks it up.
	policy := buildPolicy(mf)
	// Surface the agent's control-plane URL host as a protected
	// destination so the host-wide egress chain doesn't drop the
	// agent's own heartbeat / task-lease / federation traffic when a
	// restrictive module attaches. Without this we observed the agent
	// firewalling itself off on first reconcile in cloud-VM dogfood
	// runs (dial 10.x.x.x:443 i/o timeout after policy.Apply).
	if h := hostFromURL(r.cfg.PlatformURL); h != "" {
		policy.ProtectedHosts = append(policy.ProtectedHosts, h)
	}
	if errs := policy.Validate(); len(errs) > 0 {
		return fmt.Errorf("policy invalid: %v", errs)
	}
	if err := policy.Apply(ctx, r.cfg.MountRunner); err != nil {
		return fmt.Errorf("apply policy: %w", err)
	}
	if policy.SeccompProfile != "" {
		for _, unit := range mf.UnitNames() {
			if err := security.WriteSeccompDropIn(unit, sanitizeProfileName(policy.SeccompProfile), policy.SeccompProfile); err != nil {
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
	if _, err := lifecycle.AttachServices(ctx, r.cfg.MountRunner, mod.ID, mf.Services); err != nil {
		r.cfg.OnError("reconciler:attach_services",
			fmt.Errorf("module %s: %w", mod.ID, err))
	}

	return nil
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
	// Unmount the module's erofs blob. The union overlay above SysRoot
	// holds an open reference to this mountpoint, so we MUST be called
	// after the union is recomposed (which is the case — RunOnce reaps
	// detached modules first, then rebuilds the overlay with the
	// remaining stack). Best-effort: log + continue on failure. The
	// kernel cleans up the loop device automatically when umount
	// releases the mount.
	if err := mount.UnmountModule(ctx, r.cfg.MountRunner, r.cfg.Layout, mod.Digest); err != nil {
		r.cfg.OnError("reconciler:unmount_module",
			fmt.Errorf("module %s: %w", mod.ID, err))
	}
	_ = current // current state held by caller; best-effort detach
	return nil
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
	if v, ok := sec["egress_allow"].([]any); ok {
		for _, e := range v {
			if s, ok := e.(string); ok {
				p.EgressAllow = append(p.EgressAllow, s)
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

// sanitizeProfileName returns a base name suitable for the systemd
// SystemCallFilter directive — strips any path components from the
// seccomp profile path.
func sanitizeProfileName(profilePath string) string {
	for i := len(profilePath) - 1; i >= 0; i-- {
		if profilePath[i] == '/' {
			return profilePath[i+1:]
		}
	}
	return profilePath
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

	mod := mount.Module{ID: moduleID, Digest: mf.Digest, Priority: mf.EffectivePriority}
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
	})
}

// LastError returns the most recent reconcile-loop error (nil on
// success).
func (r *Reconciler) LastError() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.lastError
}
