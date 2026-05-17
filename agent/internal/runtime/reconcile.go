package runtime

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"sync"
	"time"

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
	// Puller pulls module artifacts (composefs blob + cosign bundle).
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
	// DryRun, when true, computes the diff + plan but skips all
	// mutations (no pull, no mount, no systemd action).
	DryRun bool
	// OnError surfaces non-fatal reconcile-stage errors. Persistent
	// errors stay in the reconciler's lastErrors field for heartbeat
	// reporting.
	OnError func(stage string, err error)
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
		m, err := manifest.LoadOrFetch(r.cfg.ManifestClient, r.cfg.ManifestRoot, mod.ID, 0)
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

	// Attaches in priority order (low → high).
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
	}

	// Filter out detached modules from current.
	if len(toDetach) > 0 {
		detached := make(map[string]bool, len(toDetach))
		for _, m := range toDetach {
			detached[m.Digest] = true
		}
		filtered := current.AttachedModules[:0]
		for _, m := range current.AttachedModules {
			if !detached[m.Digest] {
				filtered = append(filtered, m)
			}
		}
		current.AttachedModules = filtered
	}

	if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
		r.lastError = fmt.Errorf("save state: %w", err)
		return r.lastError
	}

	r.lastReconcileAt = time.Now()
	r.lastError = nil
	return nil
}

// attachModule pulls + verifies + mounts a single module.
func (r *Reconciler) attachModule(ctx context.Context, mod mount.Module, mf *manifest.Manifest) error {
	ref := &oci.ModuleArtifactRef{
		ModuleID: mod.ID,
		Digest:   mod.Digest,
		// DownloadURL filled by the FetchManifest path; for now use the
		// platform endpoint shape (manifest.json carries the URL when
		// the artifact is published).
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

	// Apply security policy. SeccompProfile is a path inside the
	// module's mounted root; the drop-in for each unit is written
	// here so subsequent systemctl start picks it up.
	policy := buildPolicy(mf)
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

	// P8.1 — Service lifecycle. lifecycle.AttachServices writes one
	// systemd unit file per system_module_services row, runs
	// daemon-reload, then starts services in topological order over
	// declared dependencies. Modules without services are an
	// authoring error and surface as an empty-attach no-op (logged
	// via OnError).
	if len(mf.Services) == 0 {
		r.cfg.OnError("reconciler:no_services",
			fmt.Errorf("module %s has no services; nothing to attach (authoring bug — every module must declare at least one system_module_services row)", mod.ID))
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
	// topological stop + unit-file removal + daemon-reload. Modules
	// without services (authoring bug or stale on-disk manifest)
	// degrade to no-op silently — there's nothing to stop.
	if mf != nil && len(mf.Services) > 0 {
		if _, err := lifecycle.DetachServices(ctx, r.cfg.MountRunner, mod.ID, mf.Services); err != nil {
			r.cfg.OnError("reconciler:detach_services",
				fmt.Errorf("module %s: %w", mod.ID, err))
		}
	}
	_ = current // current state held by caller; best-effort detach
	return nil
}

// buildPolicy constructs a security.Policy from the manifest's
// config["security"] block. Returns an empty policy when no security
// block is present.
func buildPolicy(m *manifest.Manifest) *security.Policy {
	p := &security.Policy{}
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

	mf, err := manifest.LoadOrFetch(r.cfg.ManifestClient, r.cfg.ManifestRoot, moduleID, 0)
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
	manifests := map[string]*manifest.Manifest{moduleID: mf}
	if err := r.attachModule(ctx, mod, mf); err != nil {
		return "", err
	}

	current.AttachedModules = append(current.AttachedModules, mod)
	if err := mount.SaveState(r.cfg.StatePath, current); err != nil {
		return "", fmt.Errorf("save state: %w", err)
	}
	_ = manifests
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
	ModulesClient ModulesClient
	ManifestClient manifest.Client
	ManifestRoot  string
	Puller        PullerAPI
	Verifier      verify.Verifier
	Fsverity      *verify.FsVerifier
	MountRunner   mount.Runner
	Layout        mount.Layout
	StatePath     string
	DryRun        bool
	OnError       func(stage string, err error)
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
