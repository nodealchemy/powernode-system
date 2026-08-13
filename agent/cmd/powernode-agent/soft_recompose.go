package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
	"github.com/nodealchemy/powernode-system/agent/internal/identity"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime"
)

// softRecomposeCmd is the middle rung of the recompose ladder (see
// internal/runtime/softreboot.go): compose the platform's CURRENT desired
// module set as a fresh union at /run/nextroot — the same ComposeForPivot a
// cold boot runs, with its own scratch tmpfs — and, with --execute, apply
// it via `systemctl soft-reboot`. Userspace restarts in seconds; the
// kernel, bootloader, A/B slots, and enrollment are untouched.
//
// Use it when the hot tier refuses: a reboot_required module changed
// (base-os), or a live materialization tripped the scratch budget
// (reconciler:recompose_budget).
func softRecomposeCmd() *cobra.Command {
	var execute bool
	c := &cobra.Command{
		Use:   "soft-recompose",
		Short: "Compose the desired module set at /run/nextroot; --execute applies it via systemd soft-reboot",
		Long: `soft-recompose stages a full recomposition of this node's assigned module
set at /run/nextroot, ready for a userspace-only reboot:

  - the union is composed by the same code path a cold boot uses, so what
    soft-reboot switches into is exactly what the next cold boot would run;
  - the kernel keeps running: no bootloader, no initramfs, no re-enrollment,
    downtime is one service stop/start cycle (seconds);
  - refused while an A/B boot-image upgrade is armed, on non-pivot nodes,
    and on systemd older than 254.

Without --execute this only prepares and reports; each prepare mounts a
fresh nextroot scratch tmpfs (superseded ones are reclaimed at the next
full reboot).`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx := context.Background()
			out := cmd.OutOrStdout()

			if err := runtime.SoftRecomposePreflight(ctx, mount.ExecRunner{}); err != nil {
				return err
			}

			pkiDir := enroll.ResolveDefaultPKIDir()
			platformURL := enroll.ReadPlatformURL(enroll.PathsUnder(pkiDir))
			if platformURL == "" {
				if ident, err := identity.DefaultResolver().Resolve(ctx); err == nil && ident != nil {
					platformURL = ident.PlatformURL
				}
			}
			if platformURL == "" {
				return fmt.Errorf("soft-recompose: could not resolve platform URL (enrolled URL empty and identity discovery failed)")
			}

			// One scratch per prepare — see mount.NextrootLayout's doc for
			// why a fresh generation each time is the only safe option.
			layout := mount.NextrootLayout(time.Now().UTC().Format("20060102t150405z"))
			fmt.Fprintf(out, "[soft-recompose] platform=%s sysroot=%s scratch=%s\n",
				platformURL, layout.SysRoot, layout.ScratchRoot)

			// The breadcrumb is captured, NOT written: on-disk it would tell
			// the LKG capturer this boot composed a set it is not running
			// (soft-reboot keeps the kernel boot ID, so the capturer cannot
			// tell the difference). It is committed below, at execute time.
			var bc *runtime.BootComposedBreadcrumb
			composer, err := runtime.NewPivotComposerAt(platformURL, pkiDir, layout,
				func(b *runtime.BootComposedBreadcrumb) { bc = b },
				func(stage string, cerr error) {
					fmt.Fprintf(os.Stderr, "[soft-recompose:compose:%s] %v\n", stage, cerr)
				})
			if err != nil {
				return fmt.Errorf("build nextroot composer: %w", err)
			}
			if err := composer.ComposeForPivot(ctx, layout.SysRoot); err != nil {
				return fmt.Errorf("compose union at %s: %w", layout.SysRoot, err)
			}
			bound, err := prepareNextrootMounts(layout.SysRoot)
			if err != nil {
				return fmt.Errorf("bind durable mounts into %s: %w", layout.SysRoot, err)
			}

			// SECOND survival gate. It cannot live in SoftRecomposePreflight:
			// the mounts it checks are the ones ComposeForPivot and
			// prepareNextrootMounts just created, so at preflight time they
			// read LoadState=not-found and would refuse forever.
			//
			// It is EVALUATED in both modes but only ENFORCED under --execute,
			// and the asymmetry is deliberate. Prepare mode changes nothing
			// about the next boot, so there is no unsafe act to refuse; making
			// it fail would break the documented dry run on every node that has
			// not yet received the drop-ins, while adding no safety. Reporting
			// the refusal instead keeps the dry run's real value — it is how an
			// operator learns --execute would be refused, without finding out by
			// running it.
			//
			// Under --execute it runs BEFORE the breadcrumb commit below, so a
			// soft-reboot that would silently not happen never leaves a record
			// claiming it did. That ordering is the honesty fix and is pinned by
			// TestSoftRecompose_GateRunsBeforeTheBreadcrumbAndTheSoftReboot.
			doomedLayers, gateErr := runtime.NextrootSurvivalGate(ctx, mount.ExecRunner{}, layout, bound)
			if gateErr != nil && execute {
				return gateErr
			}
			for _, l := range doomedLayers {
				fmt.Fprintf(out, "[soft-recompose] WARNING: %s is scheduled for teardown at umount.target. "+
					"Whether the new root still serves that layer afterwards is UNSETTLED — see "+
					"NextrootSurvivalGate: the design doc says overlayfs holds private clones, but a live "+
					"pivot node was observed losing a layer's files this way (mount/union_lowers.go). "+
					"Not a refusal (no drop-in can name a digest-derived unit), but do not treat --execute "+
					"as proven on real hardware\n", l)
			}

			if !execute {
				fmt.Fprintln(out, "\nPREPARED — /run/nextroot holds the freshly composed union.")
				if gateErr != nil {
					fmt.Fprintf(out, "\nBUT --execute WOULD BE REFUSED:\n  %v\n\n", gateErr)
					fmt.Fprintln(out, "Nothing about the next boot has changed and no breadcrumb was written,")
					fmt.Fprintln(out, "so this prepared root is safe to abandon; a full reboot clears it.")
					fmt.Fprintln(out, "Fix the mount survival above, then re-run with --execute.")
					return nil
				}
				fmt.Fprintln(out, "Pass --execute to apply it now via `systemctl soft-reboot`")
				fmt.Fprintln(out, "(userspace-only restart: services bounce once, kernel and enrollment stay).")
				fmt.Fprintln(out, "The boot breadcrumb was deliberately NOT written; abandoning this")
				fmt.Fprintln(out, "prepared root is safe and a full reboot clears it entirely.")
				return nil
			}

			// Commit point. Preserve the prior breadcrumb so a failed
			// soft-reboot invocation can put it back — otherwise the LKG
			// capturer could later promote a set this boot never ran.
			prior, priorErr := os.ReadFile(runtime.BootBreadcrumbPath)
			if bc != nil {
				if err := runtime.WriteBreadcrumb(runtime.BootBreadcrumbPath, bc); err != nil {
					return fmt.Errorf("write boot breadcrumb: %w", err)
				}
			}
			fmt.Fprintln(out, "[soft-recompose] invoking systemctl soft-reboot — userspace is going down NOW")
			if err := (mount.ExecRunner{}).Run(ctx, "systemctl", "soft-reboot"); err != nil {
				// Undo the breadcrumb we just committed. Both branches
				// matter: when there WAS no prior breadcrumb the correct
				// undo is to REMOVE the file, not to leave ours behind —
				// otherwise a composition that never ran sits on disk
				// carrying the current boot id, which the LKG capturer's
				// staleness check happily accepts and may freeze as
				// last-known-good. Restore uses the same atomic writer as
				// the write path so a crash here cannot truncate it.
				if bc != nil {
					var rerr error
					if priorErr == nil {
						rerr = fsutil.AtomicWrite(runtime.BootBreadcrumbPath, prior, 0o644)
					} else if os.IsNotExist(priorErr) {
						if remErr := os.Remove(runtime.BootBreadcrumbPath); remErr != nil && !os.IsNotExist(remErr) {
							rerr = remErr
						}
					} else {
						rerr = priorErr
					}
					if rerr != nil {
						fmt.Fprintf(os.Stderr, "[soft-recompose] WARNING: soft-reboot failed AND the breadcrumb could not be reverted (%v) — the file at %s now describes a composition this boot is NOT running; remove it or full-reboot before the LKG gate next runs\n", rerr, runtime.BootBreadcrumbPath)
					}
				}
				return fmt.Errorf("systemctl soft-reboot: %w", err)
			}
			return nil
		},
	}
	c.Flags().BoolVar(&execute, "execute", false, "apply the prepared composition now via `systemctl soft-reboot` (default: prepare + report only)")
	return c
}

// nextrootBindSources are the ONLY mounts bound into a soft-reboot
// nextroot. The list is deliberately short, and /run is deliberately
// ABSENT — see prepareNextrootMounts.
var nextrootBindSources = []string{"/persist"}

// prepareNextrootMounts is the soft-reboot analogue of
// bindAndCheckSysroot, and it exists because reusing that function here
// DESTROYS THE RUNNING NODE.
//
// bindAndCheckSysroot rbinds /persist, /dev, /sys, /proc and /run into the
// target. That is correct for the initramfs switch_root path, where the
// target is /sysroot — a directory OUTSIDE /run. It is catastrophic for a
// soft-reboot target, because that target is /run/nextroot, which lives
// INSIDE /run: `mount --rbind /run /run/nextroot/run` recursively binds a
// tree that contains its own destination, pulling the live
// /run/powernode/scratch (the tmpfs backing the RUNNING root's overlay
// upperdir) and every erofs module mount into the nextroot's subtree.
//
// A second `soft-recompose` then calls MountUnion, whose plain umount of
// the existing /run/nextroot fails EBUSY and falls back to `umount -l` —
// and the lazy detach takes the whole propagated subtree with it. The live
// root loses its upperdir and all of its lower layers while running.
//
// Reproduced in an isolated mount namespace 2026-08-07: after the second
// prepare, /run/powernode/scratch and every /run/powernode/modules/* mount
// read GONE from /proc/self/mountinfo; an otherwise identical run that
// binds everything EXCEPT /run leaves them all OK. Two prepares is not an
// exotic sequence — prepare is the DEFAULT mode of this command, the one
// that does not pass --execute and reads as the safe dry run.
//
// So: bind only what the post-soft-reboot userspace genuinely cannot
// reconstruct — /persist, which carries the enrolled PKI, the boot LKG and
// the durable /var, and which is a top-level mount rather than one under
// /run, so binding it creates no containment loop. Note that after this
// change /persist reaches the new root SOLELY via run-nextroot-persist.mount
// — that bind is the single load-bearing carrier. CriticalSoftRebootMounts
// (the preflight) cannot check it, because it does not exist yet when the
// preflight runs; that is why the destinations established here are RETURNED,
// and handed to runtime.NextrootSurvivalGate once they are real. Returning
// them rather than re-deriving the list at the gate is deliberate: a new bind
// source then cannot quietly add an unchecked carrier.
//
// The API filesystems are deliberately NOT bound, and that is a REAL
// DEPENDENCY, not merely dropping something redundant: we now RELY on
// systemd's switch-root moving /dev, /proc, /sys and /run into the new
// root itself (src/shared/switch-root.c does exactly that). If that ever
// stops holding, the new root comes up with no /dev — unrecoverable in the
// same way losing /persist is. Binding them here is not an option: they
// live under paths whose peer groups reintroduce the detach bug above.
func prepareNextrootMounts(sysroot string) ([]string, error) {
	var dests []string
	for _, src := range nextrootBindSources {
		// The hazard is SHARED PEER GROUPS, not path containment as such.
		// Every mount on a fleet node is shared:, so binding ANY source
		// under /run creates peer copies of /run's children beneath the
		// nextroot — and the next `umount -l` propagates the detach back
		// to the live originals. Path containment alone would wave
		// through e.g. "/run/powernode", which does not contain
		// /run/nextroot yet reproduces the bug exactly. Both tests, so a
		// future edit fails loudly instead of silently unmounting the
		// running root's layers.
		if src == "/run" || strings.HasPrefix(src, "/run/") {
			return nil, fmt.Errorf("refusing to bind %s into %s: sources under /run share a peer group with the target's parent, and a later lazy umount would detach the live root's scratch and module mounts", src, sysroot)
		}
		if strings.HasPrefix(sysroot, strings.TrimSuffix(src, "/")+"/") {
			return nil, fmt.Errorf("refusing to bind %s into %s: the source contains the target, which would detach live mounts on teardown", src, sysroot)
		}
		dst := filepath.Join(sysroot, src)
		if err := os.MkdirAll(dst, 0o755); err != nil {
			return nil, fmt.Errorf("mkdir %s: %w", dst, err)
		}
		// Recorded whether we mounted it now or found it already mounted:
		// either way it is a load-bearing carrier the survival gate must
		// check. Skipping the already-mounted case would hide the carrier
		// on exactly the repeat-prepare path.
		dests = append(dests, dst)
		if isMountedAt(dst) {
			continue
		}
		out, err := exec.Command("mount", "--rbind", src, dst).CombinedOutput()
		if err != nil {
			return nil, fmt.Errorf("rbind %s -> %s: %w (output: %s)", src, dst, err, out)
		}
	}

	initPath, err := ensureCanonicalInit(sysroot)
	if err != nil {
		return nil, err
	}
	fmt.Printf("[soft-recompose] nextroot ready — init=%s, bound=%v (NOT /run: see prepareNextrootMounts)\n",
		initPath, nextrootBindSources)
	return dests, nil
}
