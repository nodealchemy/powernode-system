// Subcommand definitions. Each command's actual logic lives in an internal
// package; this file only wires the Cobra command surface and parses flags.
//
// Stubbed commands print a "not yet implemented (M2.X)" message so the
// binary builds cleanly while individual subcommand implementations land
// across M2 sub-tasks.
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

	"github.com/powernode/platform/extensions/system/agent/internal/enroll"
	"github.com/powernode/platform/extensions/system/agent/internal/runtime"
)

// --- boot --------------------------------------------------------------------
func bootCmd() *cobra.Command {
	var (
		identityFile  string
		caFile        string
		bootstrapTok  string
		dryRun        bool
	)
	c := &cobra.Command{
		Use:   "boot",
		Short: "First-boot orchestration (initramfs init-bottom path)",
		Long: `Runs from initramfs as PID 1's child. Discovers identity, enrolls via
the bootstrap token, pulls modules, mounts the composefs+overlayfs union, and
switch_root's into the assembled rootfs.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("[powernode-agent boot] not yet implemented (M2.B identity + M2.C enroll + M2.D mount)")
			_ = identityFile
			_ = caFile
			_ = bootstrapTok
			_ = dryRun
			_ = context.Background()
			return nil
		},
	}
	c.Flags().StringVar(&identityFile, "identity-file", "/etc/identity.cfg", "path to local identity config (fallback when no cloud metadata)")
	c.Flags().StringVar(&caFile, "ca-file", "", "platform CA bundle (passed via initramfs)")
	c.Flags().StringVar(&bootstrapTok, "bootstrap-token", "", "single-use enrollment token (overrides identity-file)")
	c.Flags().BoolVar(&dryRun, "dry-run", false, "print plan without executing mounts")
	return c
}

// --- service -----------------------------------------------------------------
func serviceCmd() *cobra.Command {
	var (
		platformURL       string
		heartbeatInterval time.Duration
		pkiDir            string
	)
	c := &cobra.Command{
		Use:   "service",
		Short: "Long-lived agent loop (heartbeat, task lease, cert rotation)",
		RunE: func(cmd *cobra.Command, args []string) error {
			svc := runtime.New(runtime.Config{
				PlatformURL:       platformURL,
				AgentVersion:      Version,
				HeartbeatInterval: heartbeatInterval,
				PKIDir:            pkiDir,
				OnError: func(stage string, err error) {
					fmt.Fprintf(os.Stderr, "[powernode-agent service] %s: %v\n", stage, err)
				},
			})
			return svc.Run(cmd.Context())
		},
	}
	c.Flags().StringVar(&platformURL, "platform-url", "", "platform base URL (overrides identity-discovered URL)")
	c.Flags().DurationVar(&heartbeatInterval, "heartbeat-interval", 30*time.Second, "interval between heartbeats")
	c.Flags().StringVar(&pkiDir, "pki-dir", enroll.PKIDir, "directory containing node.crt/node.key/ca-bundle.crt")
	// --platform-url is intentionally NOT required: the agent self-bootstraps
	// from identity (kernel cmdline / virtio-fw-cfg / cloud metadata). Pass
	// the flag only when the operator wants to override the discovered URL.
	return c
}

// --- prepare-root ------------------------------------------------------------
// prepareRootCmd mounts the module-rootfs union at /sysroot for switch-root.
//
// Pre-conditions:
//   - 9p share `powernode_modules` is exposed by the host (via libvirt
//     <filesystem> block in DomainXmlBuilder), backing /var/lib/powernode/modules
//   - Each named module has a rootfs/ subtree at <share>/<name>/rootfs/
//   - The agent has already enrolled (cert at /persist/var/lib/powernode/pki/)
//
// Mount layout produced:
//   /run/powernode/modules                 (9p share, ro)
//   /run/powernode/overlay/{upper,work}    (tmpfs scratch)
//   /sysroot                               (overlayfs union)
//     /sysroot/persist  ← bind /persist (PKI + agent state survive pivot)
//     /sysroot/dev      ← rbind /dev
//     /sysroot/sys      ← rbind /sys
//     /sysroot/proc     ← rbind /proc
//     /sysroot/run      ← rbind /run    (lets agent in new root see fw-cfg /
//                                        9p share without remounting)
//
// Caller (typically powernode-mount.service) follows up with
//   systemctl switch-root /sysroot /sbin/init
// which kills the initramfs systemd and re-execs in the new rootfs.
func prepareRootCmd() *cobra.Command {
	var (
		modulesSource string
		sysroot       string
		modules       []string
		ninePTag      string
	)
	c := &cobra.Command{
		Use:   "prepare-root",
		Short: "Mount module rootfs as overlayfs at /sysroot, ready for switch-root",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runPrepareRoot(modulesSource, sysroot, ninePTag, modules)
		},
	}
	c.Flags().StringVar(&modulesSource, "modules-source", "/run/powernode/modules", "where the 9p share is mounted")
	c.Flags().StringVar(&sysroot, "sysroot", "/sysroot", "target mount point for the union")
	c.Flags().StringSliceVar(&modules, "modules", []string{"system-base"}, "module names in priority order, low to high")
	c.Flags().StringVar(&ninePTag, "9p-tag", "powernode_modules", "9p share tag (must match libvirt <target dir=...>)")
	return c
}

func runPrepareRoot(modulesSource, sysroot, ninePTag string, modules []string) error {
	fmt.Printf("[prepare-root] modules=%v sysroot=%s\n", modules, sysroot)

	// 1. Ensure 9p share is mounted.
	if !isMountedAt(modulesSource) {
		if err := os.MkdirAll(modulesSource, 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", modulesSource, err)
		}
		out, err := exec.Command("mount", "-t", "9p", "-o",
			"trans=virtio,version=9p2000.L,ro,msize=104857600",
			ninePTag, modulesSource).CombinedOutput()
		if err != nil {
			return fmt.Errorf("mount 9p %q at %s: %w (output: %s)", ninePTag, modulesSource, err, out)
		}
		fmt.Printf("[prepare-root] mounted 9p share at %s\n", modulesSource)
	}

	// 2. Validate each module has a rootfs/ dir.
	var lowers []string
	for _, m := range modules {
		rootfsPath := filepath.Join(modulesSource, m, "rootfs")
		if _, err := os.Stat(rootfsPath); err != nil {
			return fmt.Errorf("module %q rootfs not found at %s: %w", m, rootfsPath, err)
		}
		lowers = append(lowers, rootfsPath)
	}
	if len(lowers) == 0 {
		return fmt.Errorf("no modules supplied")
	}

	// 3. tmpfs upper + work; sysroot mountpoint.
	const workBase = "/run/powernode/overlay"
	upper := filepath.Join(workBase, "upper")
	work := filepath.Join(workBase, "work")
	for _, d := range []string{upper, work, sysroot} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", d, err)
		}
	}

	// 4. Reverse lowers — overlayfs reads lowerdir top-to-bottom (highest priority
	// first), but our convention is to pass low-to-high.
	reversed := make([]string, len(lowers))
	for i, l := range lowers {
		reversed[len(lowers)-1-i] = l
	}
	lowerdir := strings.Join(reversed, ":")

	// 5. Mount overlayfs.
	overlayOpts := fmt.Sprintf("lowerdir=%s,upperdir=%s,workdir=%s", lowerdir, upper, work)
	fmt.Printf("[prepare-root] mount -t overlay -o %s overlay %s\n", overlayOpts, sysroot)
	out, err := exec.Command("mount", "-t", "overlay", "overlay", "-o", overlayOpts, sysroot).CombinedOutput()
	if err != nil {
		return fmt.Errorf("mount overlay at %s: %w (output: %s)", sysroot, err, out)
	}

	// 6. Bind-mount /persist, /dev, /sys, /proc, /run into /sysroot.
	// rbind so submounts (like /sys/firmware/qemu_fw_cfg) come along.
	for _, src := range []string{"/persist", "/dev", "/sys", "/proc", "/run"} {
		dst := filepath.Join(sysroot, src)
		if err := os.MkdirAll(dst, 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", dst, err)
		}
		if isMountedAt(dst) {
			continue
		}
		out, err := exec.Command("mount", "--rbind", src, dst).CombinedOutput()
		if err != nil {
			return fmt.Errorf("rbind %s -> %s: %w (output: %s)", src, dst, err, out)
		}
	}

	// 7. Sanity-check: there's an init in the new root.
	candidates := []string{
		filepath.Join(sysroot, "sbin/init"),
		filepath.Join(sysroot, "lib/systemd/systemd"),
		filepath.Join(sysroot, "usr/lib/systemd/systemd"),
	}
	var found string
	for _, p := range candidates {
		if _, err := os.Stat(p); err == nil {
			found = p
			break
		}
	}
	if found == "" {
		return fmt.Errorf("no init found in %s (tried %v)", sysroot, candidates)
	}
	fmt.Printf("[prepare-root] OK — init=%s\n", found)
	return nil
}

func isMountedAt(path string) bool {
	data, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[1] == path {
			return true
		}
	}
	return false
}

// --- enroll ------------------------------------------------------------------
func enrollCmd() *cobra.Command {
	var (
		token       string
		platformURL string
		caFile      string
		subject     string
		dmiUUID     string
		out         string
	)
	c := &cobra.Command{
		Use:   "enroll",
		Short: "Token → mTLS cert exchange against /node_api/enroll",
		RunE: func(cmd *cobra.Command, args []string) error {
			caPEM, err := os.ReadFile(caFile)
			if err != nil {
				return fmt.Errorf("read CA: %w", err)
			}
			ec := &enroll.Client{
				PlatformURL:  platformURL,
				CABundlePEM:  caPEM,
				AgentVersion: Version,
			}
			id, err := ec.Enroll(cmd.Context(), enroll.EnrollRequest{
				BootstrapToken: token,
				Subject:        subject,
				DMIUUID:        dmiUUID,
			})
			if err != nil {
				return err
			}
			id.CABundlePEM = caPEM
			if err := enroll.Save(id, enroll.PathsUnder(out)); err != nil {
				return fmt.Errorf("save: %w", err)
			}
			fmt.Printf("Enrolled instance=%s subject=%s not_after=%s\n",
				id.InstanceID, id.MTLSSubject, id.NotAfter.Format("2006-01-02"))
			return nil
		},
	}
	c.Flags().StringVar(&token, "token", "", "bootstrap token (required)")
	c.Flags().StringVar(&platformURL, "platform-url", "", "platform base URL (required)")
	c.Flags().StringVar(&caFile, "ca", "", "platform CA bundle PEM file (required)")
	c.Flags().StringVar(&subject, "subject", "", "expected mTLS subject CN (typically instance UUID; required)")
	c.Flags().StringVar(&dmiUUID, "dmi-uuid", "", "optional DMI/SMBIOS UUID for the platform's resolve_instance hint")
	c.Flags().StringVar(&out, "out", enroll.PKIDir, "directory to write cert + key + chain")
	_ = c.MarkFlagRequired("token")
	_ = c.MarkFlagRequired("platform-url")
	_ = c.MarkFlagRequired("ca")
	_ = c.MarkFlagRequired("subject")
	return c
}

// --- verify ------------------------------------------------------------------
func verifyCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "verify <module-path>",
		Short: "Verify cosign signature + fs-verity hash on a local module artifact",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("[powernode-agent verify] not yet implemented (M2.D)")
			return nil
		},
	}
}

// --- introspect --------------------------------------------------------------
func introspectCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "introspect",
		Short: "Print the agent's view of itself (identity, modules, certs, mounts)",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("[powernode-agent introspect] not yet implemented")
			return nil
		},
	}
}

// --- attach / detach ---------------------------------------------------------
func attachCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "attach <module-id>",
		Short: "Mount a module into the union (legacy ipn -a)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Printf("[powernode-agent attach %s] not yet implemented (M2.D)\n", args[0])
			return nil
		},
	}
}

func detachCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "detach <module-id>",
		Short: "Unmount a module from the union (legacy ipn -d)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Printf("[powernode-agent detach %s] not yet implemented (M2.D)\n", args[0])
			return nil
		},
	}
}

// --- update / commit / status / exec / sync / init / volume-setup / puppet ---
func updateCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "update",
		Short: "Reconcile assignments from /node_api/modules (legacy ipn -u)",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("[powernode-agent update] not yet implemented (M2.E)")
			return nil
		},
	}
}

func commitCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "commit <module-id>",
		Short: "Capture live delta + push as new module version (legacy ipn -c)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Printf("[powernode-agent commit %s] not yet implemented\n", args[0])
			return nil
		},
	}
}

func statusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Print attach/detach state of all modules (legacy ipn -s)",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("[powernode-agent status] not yet implemented")
			return nil
		},
	}
}

func execCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "exec <script-id>",
		Short: "Fetch + run a NodeScript from /node_api/files/scripts/:id (legacy ipn -e)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Printf("[powernode-agent exec %s] not yet implemented\n", args[0])
			return nil
		},
	}
}

func syncCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "sync",
		Short: "One reconcile cycle: pull config + modules + run puppet (legacy ipn -S)",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("[powernode-agent sync] not yet implemented")
			return nil
		},
	}
}

func initCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "init <module-id> <action>",
		Short: "Run a module's init action; action is start|stop|restart (legacy ipn -I)",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Printf("[powernode-agent init %s %s] not yet implemented\n", args[0], args[1])
			return nil
		},
	}
}

func volumeSetupCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "volume-setup <device>",
		Short: "Partition + format a disk per node policy (legacy ipn -X)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Printf("[powernode-agent volume-setup %s] not yet implemented\n", args[0])
			return nil
		},
	}
}

func puppetCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "puppet",
		Short: "Puppet integration (apply manifests fetched from platform)",
	}
	c.AddCommand(&cobra.Command{
		Use:   "apply",
		Short: "Fetch /node_api/puppet/resources and run `puppet apply` (legacy ipn -p)",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("[powernode-agent puppet apply] not yet implemented")
			return nil
		},
	})
	return c
}
