package runtime

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/etcidentity"
	"github.com/nodealchemy/powernode-system/agent/internal/etcsudoers"
	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// ComposeForPivot performs a one-shot, native compose for the direct_kernel /
// pivot_root boot model (Option B — the module union becomes the OS). The caller
// (the boot orchestrator) runs this in the initramfs, then switch_root's into
// `sysroot`.
//
// Unlike RunOnce (the cloud_init reconcile loop) this:
//   - mounts ALL assigned modules + composes the overlay union once, up front;
//   - renders identity (passwd/group/shadow/gshadow) + sudoers INTO the composed
//     union at `sysroot` rather than the live initramfs / ;
//   - renders units in native mode (no RootDirectory) and ENABLES them via
//     systemctl --root instead of starting them — systemd-in-the-union starts
//     them on boot after switch_root;
//   - starts nothing and persists no state.json (each boot recomposes from the
//     freshly-fetched assigned set, so a removed module can't ghost-start).
//
// Returns an error only for failures that would yield a broken post-pivot OS
// (no modules, a module that won't pull/verify/mount, or a failed union
// compose). Identity / sudoers / unit-enable failures surface via OnError but
// don't abort — a partially-populated union is still bootable and self-heals on
// the next boot.
//
// Note: durable-storage binding (postgres /persist etc.) is handled by the
// boot/initramfs mount plan (bind /persist into the union), not here.
func (r *Reconciler) ComposeForPivot(ctx context.Context, sysroot string) error {
	if sysroot == "" {
		sysroot = r.cfg.Layout.SysRoot
	}

	desiredModules, err := FetchAssignedModules(ctx, r.cfg.ModulesClient)
	if err != nil {
		return fmt.Errorf("fetch assigned modules: %w", err)
	}

	desired := make(mount.ModuleStack, 0, len(desiredModules))
	manifests := make(map[string]*manifest.Manifest, len(desiredModules))
	for _, mod := range desiredModules {
		if !mod.HasDataFile {
			continue // config-variety + skill modules have no blob to mount
		}
		m, err := manifest.LoadOrFetch(r.cfg.ManifestClient, r.cfg.ManifestRoot, mod.ID, r.cfg.ManifestTTL)
		if err != nil {
			r.cfg.OnError("compose:fetch_manifest", fmt.Errorf("module %s: %w", mod.ID, err))
			continue
		}
		if m.Digest == "" {
			r.cfg.OnError("compose:no_digest", fmt.Errorf("module %s has no digest (not published)", mod.ID))
			continue
		}
		desired = append(desired, mount.Module{ID: mod.ID, Digest: m.Digest, Priority: m.EffectivePriority})
		manifests[mod.ID] = m
	}
	if len(desired) == 0 {
		return errors.New("no mountable modules assigned — cannot compose a pivot root")
	}

	// Pull + verify + loop-mount every module, low→high priority. A failure here
	// is fatal: the post-pivot OS would be missing a layer.
	stack := desired.SortByPriority()
	for _, mod := range stack {
		if err := r.mountModuleArtifact(ctx, mod); err != nil {
			return fmt.Errorf("module %s: %w", mod.ID, err)
		}
	}

	// Compose the overlay union at sysroot from all mounted modules.
	overlay := &mount.Overlay{Layout: r.cfg.Layout, Runner: r.cfg.MountRunner}
	if err := overlay.MountUnion(ctx, stack); err != nil {
		return fmt.Errorf("compose union at %s: %w", sysroot, err)
	}

	// Render identity + sudoers INTO the composed union so User= + chown resolve
	// the platform-allocated UIDs when systemd-in-the-union starts services
	// post-pivot.
	manifestsSlice := make([]*manifest.Manifest, 0, len(manifests))
	for _, m := range manifests {
		manifestsSlice = append(manifestsSlice, m)
	}
	identitySet, conflicts := etcidentity.Collect(manifestsSlice)
	for _, c := range conflicts {
		r.cfg.OnError("compose:identity_conflict",
			fmt.Errorf("%s %q (source=%s)", c.Kind, c.Name, c.SourceModule))
	}
	if err := etcidentity.ApplyAt(identitySet, unionIdentityPaths(sysroot)); err != nil {
		r.cfg.OnError("compose:identity_write", err)
	}
	if err := etcsudoers.ApplyAt(etcsudoers.CollectFromManifests(manifestsSlice),
		filepath.Join(sysroot, "etc", "sudoers.d"), time.Now); err != nil {
		r.cfg.OnError("compose:sudoers_write", err)
	}

	// Render + offline-enable native units in the union (no start — systemd in
	// the union starts them on boot after switch_root).
	for _, mod := range stack {
		mf := manifests[mod.ID]
		if mf == nil {
			continue
		}
		if _, err := lifecycle.AttachServicesNative(ctx, r.cfg.MountRunner, mod.ID, mf.Services, sysroot); err != nil {
			r.cfg.OnError("compose:attach_native", fmt.Errorf("module %s: %w", mod.ID, err))
		}
	}

	return nil
}

// unionIdentityPaths returns etcidentity.Paths rooted under the composed union
// at sysroot, so the platform identity files land in the union (which becomes /
// after switch_root) rather than the live initramfs root.
func unionIdentityPaths(sysroot string) etcidentity.Paths {
	return etcidentity.Paths{
		Lock:    filepath.Join(sysroot, "etc", ".pwd.lock"),
		Passwd:  filepath.Join(sysroot, "etc", "passwd"),
		Group:   filepath.Join(sysroot, "etc", "group"),
		Shadow:  filepath.Join(sysroot, "etc", "shadow"),
		Gshadow: filepath.Join(sysroot, "etc", "gshadow"),
	}
}
