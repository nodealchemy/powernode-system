package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"

	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
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
			// Same durable/API binds + canonical-init guarantee the
			// switch_root path relies on; soft-reboot moves the nextroot
			// tree (submounts included) onto / and re-executes its init.
			if err := bindAndCheckSysroot(layout.SysRoot); err != nil {
				return fmt.Errorf("bind durable mounts into %s: %w", layout.SysRoot, err)
			}

			if !execute {
				fmt.Fprintln(out, "\nPREPARED — /run/nextroot holds the freshly composed union.")
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
				if bc != nil && priorErr == nil {
					if rerr := os.WriteFile(runtime.BootBreadcrumbPath, prior, 0o644); rerr != nil {
						fmt.Fprintf(os.Stderr, "[soft-recompose] WARNING: soft-reboot failed AND the prior breadcrumb could not be restored (%v) — run `powernode-agent soft-recompose --execute` again or full-reboot before the LKG gate next runs\n", rerr)
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
