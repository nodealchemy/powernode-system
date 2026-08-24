package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
	"github.com/nodealchemy/powernode-system/agent/internal/etcidentity"
	"github.com/nodealchemy/powernode-system/agent/internal/etcsudoers"
	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/oci"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
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

	// Resolve the module set for this boot: the live platform assignment when
	// reachable (retry-live-first), else the frozen boot-LKG fallback (#39). bc
	// is the breadcrumb of exactly what was resolved — written to /persist at the
	// end so the post-boot capturer promotes THIS set (never a later hot-
	// reconcile) and the heartbeat can report booted_from_lkg.
	desired, manifests, bc, err := r.resolveComposeSet(ctx)
	if err != nil {
		return err
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
	// Bake correct home-dir ownership into the union before pivot so the
	// switch_root'd system comes up with sshd-readable homes (the base-os
	// tmpfiles.d fragment is the boot-time backstop; this makes the union
	// correct even for a home already staged root:root).
	etcidentity.ReconcileHomeOwnership(identitySet, sysroot, r.cfg.OnError)
	if err := etcsudoers.ApplyAt(etcsudoers.CollectFromManifests(manifestsSlice),
		filepath.Join(sysroot, "etc", "sudoers.d"), time.Now); err != nil {
		r.cfg.OnError("compose:sudoers_write", err)
	}

	// Set the node's hostname in the composed union so the switch_root'd system
	// boots with its platform-assigned name. base-os masks /etc/hostname out of
	// its erofs (build-chroot identity must not ship fleet-wide), so without
	// this the union carries no /etc/hostname and systemd falls back to
	// "localhost". File-only (applyLive=false): systemd-in-the-union applies
	// /etc/hostname at boot; the initramfs's own hostname is irrelevant. No-op
	// when no authoritative source is present this boot.
	if name := desiredHostname(); name != "" {
		if _, err := etcidentity.ApplyHostname(sysroot, name, false); err != nil {
			r.cfg.OnError("compose:hostname_write", err)
		}
		// Same rationale, applied to /etc/hosts: base-os's static rootfs file
		// (masked from carrying a per-node line — hostname is unknown at build
		// time) only has the bare loopback + ::1 lines. Without this, a pivot
		// node's union has localhost resolvable but nothing resolves the node's
		// OWN hostname via /etc/hosts. This also fully repopulates /etc/hosts
		// on every compose — including the loopback line base-os already ships
		// — so a node still boots with localhost resolvable even if base-os's
		// own file is ever missing from the union for some reason.
		if _, err := etcidentity.ApplyHosts(sysroot, name); err != nil {
			r.cfg.OnError("compose:hosts_write", err)
		}
	}

	// Redirect the composed union's Traefik dynamic config + certs to durable
	// storage, when reverse-proxy-traefik is part of this boot's module set.
	// Same rationale as the hostname/hosts block above: must happen here,
	// before switch_root, not from either service's own startup script (see
	// applyTraefikIngressPersistence's doc comment for the race this avoids).
	applyTraefikIngressPersistence(sysroot, TraefikIngressPersistRoot, manifests, r.cfg.OnError)

	// The privileged-approval gate is enforced on EVERY compose boot — live,
	// FromPending, and FromLKG — against the operator allowlist FROZEN alongside
	// the composed set (bc.PrivilegedModuleIDs). Enforcing only on a live boot
	// (the original design) left the highest-value case open: self-hosted nodes
	// boot FromLKG as their NORMAL path, so an unapproved privileged module
	// captured into the LKG would replay UNCONFINED there (review finding F2).
	// A set that predates this field (PrivilegedAllowlistFrozen=false) skips the
	// gate exactly as before, so the upgrade window cannot brick a node whose
	// frozen set has no allowlist. The frozen list is a snapshot: a revocation
	// takes effect once a newer set is captured, not instantly on an offline
	// node — inherent to LKG, and still strictly better than never enforcing.
	enforcePrivileged := bc != nil && bc.PrivilegedAllowlistFrozen
	if bc != nil {
		r.privilegedAllow = bc.PrivilegedModuleIDs
	}

	// Render + offline-enable native units in the union (no start — systemd in
	// the union starts them on boot after switch_root), applying the SAME
	// confinements the cloud_init attachModule path applies (IMP-01a02f70-9bfb):
	// per-module Policy.Validate, seccomp SystemCallFilter, PrivateUsers, and
	// the privileged-approval gate. The one deliberate difference remains the
	// capability set: this path writes an ADDITIVE ambient grant and does NOT
	// reset CapabilityBoundingSet (see WriteAmbientCapabilityDropInAt and the
	// reported-state note in buildHeartbeat) — that restriction needs a
	// per-module runtime-capability audit before it is safe post-pivot.
	for _, mod := range stack {
		mf := manifests[mod.ID]
		if mf == nil {
			continue
		}
		policy := buildPolicy(mf)

		// Loud refusals BEFORE the unit is enabled — a module whose security
		// block is invalid, or which requests privileged without an operator
		// grant, must not boot its services unconfined. Skipping enablement is
		// the pivot-path equivalent of attachModule returning an error; the
		// module's files are in the union but its services stay disabled, and
		// the refusal is surfaced via OnError.
		if errs := policy.Validate(); len(errs) > 0 {
			r.cfg.OnError("compose:policy_invalid",
				fmt.Errorf("module %s: %v — services NOT enabled post-pivot", mod.ID, errs))
			continue
		}
		if policy.Privileged && enforcePrivileged && !privilegedApproved(mod.ID, r.privilegedAllow) {
			r.cfg.OnError("compose:privileged_unapproved",
				fmt.Errorf("module %s requests security.privileged=true but is not in the operator-approved "+
					"privileged allowlist (privileged_module_ids); services NOT enabled post-pivot", mod.ID))
			continue
		}

		if _, err := lifecycle.AttachServicesNative(ctx, r.cfg.MountRunner, mod.ID, mf.Services, sysroot); err != nil {
			r.cfg.OnError("compose:attach_native", fmt.Errorf("module %s: %w", mod.ID, err))
		}

		for _, svc := range mf.Services {
			unit := lifecycle.UnitName(mod.ID, svc.Name)
			// PrivateUsers= is orthogonal to the privileged capability/MAC
			// opt-out (it only remaps UID/GID namespaces), so it is written for
			// ALL modules INCLUDING privileged ones — matching attachModule
			// (reconcile.go), whose divergence here (privileged modules ran in
			// the host userns on a pivot node but PrivateUsers=yes on cloud_init)
			// was review finding F4. The documented user_namespace default (true)
			// was also silently unenforced on the pivot path before this fix.
			if err := security.WriteUserNamespaceDropInAt(sysroot, unit, policy.UserNamespace); err != nil {
				r.cfg.OnError("compose:userns_dropin",
					fmt.Errorf("module %s unit %s: %w", mod.ID, unit, err))
			}
			// Privileged modules opt out of MAC/seccomp/cap confinement by
			// design; for everyone else, write the same seccomp + ambient-cap
			// drop-ins attachModule writes, into the union at sysroot.
			if policy.Privileged {
				continue
			}
			// seccomp SystemCallFilter=@<set> — inert on the pivot path before
			// this fix. buildPolicy.Validate above already refused a hostile/
			// unresolvable profile, so a value reaching here is a resolvable set.
			if policy.SeccompProfile != "" {
				if err := security.WriteSeccompDropInAt(sysroot, unit, policy.SeccompProfile); err != nil {
					r.cfg.OnError("compose:seccomp_dropin",
						fmt.Errorf("module %s unit %s: %w", mod.ID, unit, err))
				}
			}
			// Ambient capability grant (additive; does NOT reset the bounding
			// set — see the loop-header note). No-op for an empty allow list.
			if len(policy.Capabilities) > 0 {
				if err := security.WriteAmbientCapabilityDropInAt(sysroot, unit, policy.Capabilities); err != nil {
					r.cfg.OnError("compose:ambient_cap_dropin",
						fmt.Errorf("module %s unit %s: %w", mod.ID, unit, err))
				}
			}
		}
	}

	// Record what THIS boot composed (best-effort — a failed breadcrumb write
	// must not abort an otherwise-successful boot; the node just can't self-
	// provision an LKG this cycle). The post-boot capturer reads this after an
	// app-health confirm; the heartbeat reads FromLKG/age for observability.
	if bc != nil {
		if r.cfg.BreadcrumbSink != nil {
			// Soft-recompose prepare: the breadcrumb describes a composition
			// the CURRENT userspace is not running, and a soft-reboot keeps
			// the kernel boot ID, so the LKG capturer's stale-breadcrumb
			// check could not tell "prepared and executed" from "prepared
			// and abandoned". Hand it to the caller, who commits it to disk
			// only at the moment the soft-reboot is actually fired.
			r.cfg.BreadcrumbSink(bc)
		} else if err := WriteBreadcrumb(BootBreadcrumbPath, bc); err != nil {
			r.cfg.OnError("compose:breadcrumb_write", err)
		}
	}

	return nil
}

// lkgFetchAttempts / lkgFetchBackoff bound the retry-live-first behavior before
// ComposeForPivot falls back to the boot-LKG — enough to ride out a transient
// blip while the control plane is up, without hanging boot indefinitely. Vars
// for test override.
var (
	lkgFetchAttempts = 3
	lkgFetchBackoff  = 2 * time.Second
)

// resolveComposeSet obtains the module set to compose for this boot. It prefers
// the live platform assignment (retry-live-first with bounded backoff). On
// exhausted failure — and unless the fallback is disabled by sentinel/cmdline —
// it composes from the frozen, validated boot-LKG. Returns the (desired,
// manifests) pair the downstream compose logic consumes, plus a breadcrumb
// describing exactly what was resolved.
func (r *Reconciler) resolveComposeSet(ctx context.Context) (mount.ModuleStack, map[string]*manifest.Manifest, *BootComposedBreadcrumb, error) {
	desiredModules, meta, ferr := r.fetchAssignedWithRetry(ctx)
	if ferr == nil {
		desired := make(mount.ModuleStack, 0, len(desiredModules))
		manifests := make(map[string]*manifest.Manifest, len(desiredModules))
		bcMods := make([]LKGModule, 0, len(desiredModules))
		fetchedData := 0 // count of assigned data modules the platform expects mounted
		for _, mod := range desiredModules {
			lm := LKGModule{ID: mod.ID, Name: mod.Name, EffectivePriority: mod.EffectivePriority, HasDataFile: mod.HasDataFile, Variety: mod.Variety}
			if mod.HasDataFile {
				fetchedData++
				m, err := manifest.LoadOrFetch(r.cfg.ManifestClient, r.cfg.ManifestRoot, mod.ID, r.cfg.ManifestTTL)
				if err != nil {
					r.cfg.OnError("compose:fetch_manifest", fmt.Errorf("module %s: %w", mod.ID, err))
					continue
				}
				if m.Digest == "" {
					r.cfg.OnError("compose:no_digest", fmt.Errorf("module %s has no digest (not published)", mod.ID))
					continue
				}
				desired = append(desired, mount.Module{ID: mod.ID, Digest: m.Digest, Priority: m.EffectivePriority, FsverityRoot: m.FsverityRootHash})
				manifests[mod.ID] = m
				lm.EffectivePriority = m.EffectivePriority
				lm.Digest = m.Digest
				if raw, merr := json.Marshal(m); merr == nil {
					lm.Manifest = raw
				}
			}
			bcMods = append(bcMods, lm)
		}
		if len(desired) == 0 {
			return nil, nil, nil, errors.New("no mountable modules assigned — cannot compose a pivot root")
		}
		// Completeness (MED-4): a data module dropped above (unresolved manifest /
		// no digest) still lets the node boot on the rest, but the composed set is
		// NOT the complete assignment. Flag it so the capturer never freezes a
		// degraded set as last-known-good.
		incomplete := len(desired) < fetchedData
		if incomplete {
			r.cfg.OnError("compose:incomplete_set",
				fmt.Errorf("composed %d of %d assigned data modules — LKG capture will be skipped this boot", len(desired), fetchedData))
		}
		bc := &BootComposedBreadcrumb{
			ComposedAt:                time.Now().UTC(),
			BootID:                    CurrentBootID(),
			FromLKG:                   false,
			Source:                    r.cfg.PlatformURL,
			Hostname:                  meta.Hostname,
			StalenessThresholdSeconds: meta.StalenessThresholdSeconds,
			AppHealth: AppHealthCfg{
				URL:                 meta.AppHealthURL,
				RequiredConsecutive: meta.AppHealthRequiredConsecutive,
				PollIntervalSeconds: meta.AppHealthPollIntervalSeconds,
			},
			Incomplete:                incomplete,
			PrivilegedModuleIDs:       meta.PrivilegedModuleIDs,
			PrivilegedAllowlistFrozen: true,
			Modules:                   bcMods,
		}
		// Live truth supersedes any staged guess. A normal pivot node stages
		// whenever desired != composed, then live-fetches fine on its next boot —
		// leaving that file to linger at Attempts=0 until some later platform
		// outage, where it would be preferred over the LKG despite possibly having
		// been rolled back platform-side. Drop it now that we have the real answer.
		// Only a REAL boot may clear the staged set. The soft-recompose
		// prepare path runs this on a live, already-booted node where the
		// fetch always succeeds — clearing there resets the PendingMaxTries
		// attempt counter that exists to stop a bad set retrying forever,
		// and after an --execute it leaves the running composition neither
		// promoted to LKG nor staged, so the next COLD boot silently
		// reverts to the old frozen LKG. BreadcrumbSink is set only by that
		// path, so it doubles as "this is not the boot compose".
		if r.cfg.BreadcrumbSink != nil {
			// nextroot compose: leave boot state alone.
		} else if err := ClearPendingCompose(PendingComposePath); err != nil {
			r.cfg.OnError("compose:clear_pending_after_live_fetch", err)
		}
		return desired, manifests, bc, nil
	}

	// Live fetch failed. Kill-switch (default-ON): sentinel/cmdline reverts to
	// today's live-only boot — surface the original fetch error.
	if LKGFallbackDisabled(LKGDisableSentinel) {
		return nil, nil, nil, fmt.Errorf("fetch assigned modules: %w (boot-LKG fallback disabled)", ferr)
	}
	// Middle rung: a composition staged post-pivot by the running agent, not yet
	// proven to boot. On a self-hosted control plane this is the ONLY way a new
	// module set can ever be tried — the live fetch above can never succeed there,
	// because the platform it would fetch from is this node, still pre-pivot.
	// TakePendingCompose burns an attempt BEFORE we compose, so a set that never
	// comes back cannot retry forever; when the attempts run out we fall through
	// to the frozen LKG below exactly as if it had never been staged.
	if pend := TakePendingCompose(PendingComposePath, r.cfg.Layout.ModuleCachePath, r.cfg.OnError); pend != nil {
		desired, manifests, cerr := pend.Set.ToComposeInputs()
		if cerr == nil {
			r.cfg.OnError("compose:booted_from_pending", fmt.Errorf(
				"live fetch failed (%v) — composing STAGED set (attempt %d/%d, staged %s): %d modules. "+
					"The frozen LKG remains the fallback if this boot does not reach health",
				ferr, pend.Attempts, PendingMaxTries, pend.StagedAt.Format(time.RFC3339), len(desired)))
			bc := &BootComposedBreadcrumb{
				ComposedAt:                time.Now().UTC(),
				BootID:                    CurrentBootID(),
				FromLKG:                   false,
				FromPending:               true,
				Source:                    pend.Set.Source,
				NodeID:                    pend.Set.NodeID,
				Hostname:                  pend.Set.Hostname,
				StalenessThresholdSeconds: pend.Set.StalenessThresholdSeconds,
				AppHealth:                 pend.Set.AppHealth,
				PrivilegedModuleIDs:       pend.Set.PrivilegedModuleIDs,
				PrivilegedAllowlistFrozen: pend.Set.PrivilegedAllowlistFrozen,
				Modules:                   pend.Set.Modules,
			}
			return desired, manifests, bc, nil
		}
		// A staged set that cannot produce compose inputs is unusable; say so and
		// fall through rather than failing the boot over an optional rung.
		r.cfg.OnError("compose:pending_unusable", cerr)
	}

	lkg, lerr := loadValidatedBootLKG(r.cfg.Layout)
	if lerr != nil {
		// No usable fallback — fail LOUD rather than compose a half-broken root.
		return nil, nil, nil, fmt.Errorf("live fetch failed (%v) AND boot-LKG unusable: %w", ferr, lerr)
	}
	desired, manifests, cerr := lkg.ToComposeInputs()
	if cerr != nil {
		return nil, nil, nil, fmt.Errorf("boot-LKG compose inputs: %w", cerr)
	}
	// Staleness is advisory: warn loudly (→ heartbeat alert) but never block —
	// a stale boot beats a brick.
	age := time.Since(lkg.ConfirmedAt)
	if thr := stalenessThreshold(lkg.StalenessThresholdSeconds); age > thr {
		r.cfg.OnError("compose:lkg_stale",
			fmt.Errorf("booting from boot-LKG aged %s > threshold %s (control plane unreachable)", age.Round(time.Second), thr))
	}
	r.cfg.OnError("compose:booted_from_lkg",
		fmt.Errorf("live fetch failed (%v) — composed from frozen boot-LKG: %d modules, confirmed %s", ferr, len(desired), lkg.ConfirmedAt.Format(time.RFC3339)))
	bc := &BootComposedBreadcrumb{
		ComposedAt:                time.Now().UTC(),
		BootID:                    CurrentBootID(),
		FromLKG:                   true,
		LKGConfirmedAt:            lkg.ConfirmedAt,
		Source:                    lkg.Source,
		NodeID:                    lkg.NodeID,
		Hostname:                  lkg.Hostname,
		StalenessThresholdSeconds: lkg.StalenessThresholdSeconds,
		AppHealth:                 lkg.AppHealth,
		PrivilegedModuleIDs:       lkg.PrivilegedModuleIDs,
		PrivilegedAllowlistFrozen: lkg.PrivilegedAllowlistFrozen,
		Modules:                   lkg.Modules,
	}
	return desired, manifests, bc, nil
}

// fetchAssignedWithRetry calls FetchAssignedModules up to lkgFetchAttempts times
// with exponential backoff, so a transient reachability blip doesn't trip the
// boot-LKG fallback while the control plane is actually up.
func (r *Reconciler) fetchAssignedWithRetry(ctx context.Context) ([]AssignedModule, AssignmentMeta, error) {
	var lastErr error
	backoff := lkgFetchBackoff
	for attempt := 1; attempt <= lkgFetchAttempts; attempt++ {
		mods, meta, err := FetchAssignedModules(ctx, r.cfg.ModulesClient)
		if err == nil {
			return mods, meta, nil
		}
		lastErr = err
		if attempt < lkgFetchAttempts {
			select {
			case <-ctx.Done():
				return nil, AssignmentMeta{}, ctx.Err()
			case <-time.After(backoff):
			}
			backoff *= 2
		}
	}
	return nil, AssignmentMeta{}, lastErr
}

// loadValidatedBootLKG loads + fail-loud-validates the frozen boot-LKG (schema,
// checksum, per-module blob presence in the digest-keyed cache).
func loadValidatedBootLKG(layout mount.Layout) (*BootLKG, error) {
	lkg, err := LoadBootLKG(BootLKGPath)
	if err != nil {
		return nil, err
	}
	if err := ValidateBootLKG(lkg, layout.ModuleCachePath); err != nil {
		return nil, err
	}
	return lkg, nil
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

// TraefikIngressPersistRoot is where the composed union's Traefik dynamic
// config + certs are redirected so ACME-issued router/cert state survives a
// pivot reboot. Traefik's own static config (baked read-only at build time —
// modules/reverse-proxy-traefik's stage-1.5 build step) hardcodes `directory:
// /etc/traefik/dynamic`; Core::IngressConfigWriter (the Rails writer that
// actually produces the per-account dynamic YAML + certs, running inside the
// hub-backend module) independently defaults to /etc/traefik/{dynamic,certs}
// whenever that path exists and is writable (its ENV-var override is the
// alternative, but repointing it there wouldn't help — Traefik itself would
// still be watching the old, un-redirected path). Planting a symlink at that
// shared path is therefore the fix BOTH sides pick up for free, with zero
// Ruby/Traefik-static-config changes needed.
const TraefikIngressPersistRoot = "/persist/powernode-traefik"

// applyTraefikIngressPersistence redirects the composed union's
// /etc/traefik/{dynamic,certs} to durable storage when reverse-proxy-traefik
// is part of this boot's assigned module set. Without this, both dirs live
// on the pivot root's ephemeral overlay upper — every ACME-issued cert and
// Traefik dynamic router config (written at runtime by
// Core::IngressConfigWriter, inside hub-backend) is lost on reboot, and the
// HTTPS login ingress has to be manually regenerated after every reboot
// (imp 019f6c3d — the reboot-durability gap this closes).
//
// This runs BEFORE switch_root (here, in the pre-pivot compose phase), not
// from either service's own startup script: whichever of {hub-backend's
// rails process, the traefik binary} happened to start first would
// otherwise win a race against the other. In particular, Traefik opens its
// dynamic-config directory watch (inotify) almost instantly at start; an
// inotify watch tracks the inode, not the path, so if the symlink swap ran
// later inside a service's own startup script, Traefik could already be
// watching the STALE pre-swap directory and would silently never see
// newly-written config until manually restarted. Running this at compose
// time, before ANY post-pivot systemd unit starts, avoids that race
// entirely — the same reason ApplyHostname/ApplyHosts above run here rather
// than in a service script.
//
// /persist is already a live mount at this point — mounted earlier in the
// initramfs's own persist-setup step, well before ComposeForPivot runs (see
// cmd/powernode-agent's persist-setup / bindAndCheckSysroot) — so creating
// the persist-backed target directories here, at the literal host path (NOT
// sysroot-relative — /persist is a host-level mount, not part of the union
// under construction), is safe.
//
// No-op when reverse-proxy-traefik isn't part of this boot's module set (a
// hub-backend-only node has no /etc/traefik at all in the union — creating
// one would be wrong). Best-effort otherwise: any single I/O failure surfaces
// via onErr but never aborts the compose — a node that fails this step still
// boots, just without durable ingress config, exactly today's status quo.
//
// persistRoot is TraefikIngressPersistRoot in production; parameterized
// (rather than reading the const directly) purely for testability — mirrors
// etcidentity.ApplyHostname/ApplyHosts taking root as a parameter.
func applyTraefikIngressPersistence(sysroot, persistRoot string, manifests map[string]*manifest.Manifest, onErr func(stage string, err error)) {
	if _, ok := manifests["reverse-proxy-traefik"]; !ok {
		return
	}

	etcTraefik := filepath.Join(sysroot, "etc", "traefik")
	if err := os.MkdirAll(etcTraefik, 0o755); err != nil {
		onErr("compose:traefik_persist_mkdir", fmt.Errorf("%s: %w", etcTraefik, err))
		return
	}

	for _, sub := range []string{"dynamic", "certs"} {
		target := filepath.Join(persistRoot, sub)
		if err := os.MkdirAll(target, 0o755); err != nil {
			onErr("compose:traefik_persist_mkdir", fmt.Errorf("%s: %w", target, err))
			continue
		}

		link := filepath.Join(etcTraefik, sub)
		if cur, err := os.Readlink(link); err == nil && cur == target {
			continue // already correct — nothing to do
		}
		// RemoveAll handles both "doesn't exist yet" (certs — never baked at
		// build time) and "a real directory shipped in the read-only lower
		// layer" (dynamic — see stage15.sh's `mkdir -p .../etc/traefik/dynamic`)
		// identically: on the mounted overlay union this creates the whiteout
		// automatically, same as any other rm through an overlayfs union.
		if err := os.RemoveAll(link); err != nil {
			onErr("compose:traefik_persist_clear", fmt.Errorf("%s: %w", link, err))
			continue
		}
		if err := os.Symlink(target, link); err != nil {
			onErr("compose:traefik_persist_symlink", fmt.Errorf("%s -> %s: %w", link, target, err))
		}
	}
}

// NewPivotComposer builds a Reconciler for use as the boot orchestrator's
// UnionComposer on the direct_kernel/pivot_root path. It loads the mTLS
// transport client from the post-enroll PKI dir and assembles a one-shot
// reconciler via NewReconcilerForCLI — the same dependency set service.Run
// wires for the cloud_init reconcile loop (Puller, AlwaysOK verifier,
// ExecRunner, DefaultLayout), minus the long-lived loop. The returned
// *Reconciler satisfies boot.UnionComposer through ComposeForPivot, which
// mounts the assigned modules, composes the overlay union at sysroot, renders
// identity + native units, and leaves /sysroot ready for switch_root.
//
// Called by bootCmd AFTER Boot's enroll step, because the mTLS client requires
// the enrolled cert to exist on disk.
func NewPivotComposer(platformURL, pkiDir string, onError func(string, error)) (*Reconciler, error) {
	return NewPivotComposerAt(platformURL, pkiDir, mount.DefaultLayout(), nil, onError)
}

// NewPivotComposerAt is NewPivotComposer with a caller-chosen Layout and an
// optional breadcrumb sink. The soft-recompose path composes at
// mount.NextrootLayout — /run/nextroot with its OWN scratch tmpfs, sharing
// the module mounts + blob cache — and withholds the breadcrumb until the
// soft-reboot is actually fired (see ReconcilerConfig.BreadcrumbSink).
func NewPivotComposerAt(platformURL, pkiDir string, layout mount.Layout, breadcrumbSink func(*BootComposedBreadcrumb), onError func(string, error)) (*Reconciler, error) {
	if onError == nil {
		onError = func(string, error) {}
	}
	paths := enroll.PathsUnder(pkiDir)
	client, err := transport.LoadFromPKIDir(platformURL, paths)
	if err != nil {
		return nil, fmt.Errorf("load mTLS client from %s: %w", pkiDir, err)
	}
	return NewReconcilerForCLI(FactoryConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   manifest.DefaultRoot,
		Puller: &oci.Puller{
			Transport: client,
			// BlobClient(), not `client`: blob bodies are unbounded and must not ride
			// the 30s whole-request Timeout. It still routes through Client.doWith, so
			// the 401 self-heal Puller.HTTPClient documents is preserved. See DoStream.
			HTTPClient:  client.BlobClient(),
			PlatformURL: client.PlatformURL,
			Cache:       "/persist/cache/modules",
		},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    mount.ExecRunner{},
		Layout:         layout,
		StatePath:      mount.StatePath,
		OnError:        onError,
		PlatformURL:    client.PlatformURL,
		BreadcrumbSink: breadcrumbSink,
	})
}
