// Subcommand definitions. Each command's actual logic lives in an internal
// package; this file only wires the Cobra command surface and parses flags.
//
// Stubbed commands print a "not yet implemented (M2.X)" message so the
// binary builds cleanly while individual subcommand implementations land
// across M2 sub-tasks.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/nodealchemy/powernode-system/agent/cmd/powernode-agent/internal/cli"
	agentcli "github.com/nodealchemy/powernode-system/agent/cmd/powernode-agent/internal/cli"
	"github.com/nodealchemy/powernode-system/agent/internal/a2a"
	"github.com/nodealchemy/powernode-system/agent/internal/boot"
	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
	"github.com/nodealchemy/powernode-system/agent/internal/bootupgrade"
	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
	"github.com/nodealchemy/powernode-system/agent/internal/espwrite"
	"github.com/nodealchemy/powernode-system/agent/internal/identity"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime"
)

// renderCLI emits a CLI Result via the shared formatter and returns
// runErr (a *cli.CommandError carrying the structured exit code) so
// cobra propagates the error to main(). The cobra wrapper in main.go
// inspects the error for *cli.CommandError to set os.Exit code; in
// the absence of one the default exit code (1) is used.
func renderCLI(cmd *cobra.Command, res cli.Result, runErr error, jsonOut bool) error {
	mode := cli.OutputHuman
	if jsonOut {
		mode = cli.OutputJSON
	}
	out := cmd.OutOrStdout()
	if err := cli.Render(out, mode, res); err != nil {
		// Failure to render is a real error but shouldn't override the
		// runErr if there is one.
		if runErr == nil {
			runErr = err
		}
	}
	return runErr
}

var _ = errors.New // silence unused-import warnings on builds where
// RunE branches don't reference errors directly.

// --- boot --------------------------------------------------------------------
func bootCmd() *cobra.Command {
	var (
		identityFile string
		caFile       string
		bootstrapTok string
		pkiDir       string
		dryRun       bool
	)
	c := &cobra.Command{
		Use:   "boot",
		Short: "First-boot orchestration (initramfs init-bottom path)",
		Long: `Runs from initramfs as PID 1's child. Discovers identity, enrolls via
the bootstrap token, pulls modules, mounts the composefs+overlayfs union, and
switch_root's into the assembled rootfs.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			_ = identityFile // reserved for future override path
			_ = caFile       // reserved for future override path
			_ = bootstrapTok // reserved for future override path

			o := boot.Orchestrator{
				Resolver:     identity.DefaultResolver(),
				EnrollClient: &enroll.Client{},
				PKIDir:       pkiDir,
				AgentVersion: Version,
				DryRun:       dryRun,
				// direct_kernel/pivot: build the union composer from the enrolled
				// PKI after Boot's enroll step (the Reconciler's mTLS client needs
				// the cert); mountUnion then ComposeForPivot's into /sysroot.
				ComposerFactory: func(platformURL, dir string) (boot.UnionComposer, error) {
					return runtime.NewPivotComposer(platformURL, dir, func(stage string, err error) {
						fmt.Fprintf(cmd.ErrOrStderr(), "[boot:compose:%s] %v\n", stage, err)
					})
				},
				OnStage: func(stage, msg string) {
					fmt.Fprintf(cmd.OutOrStdout(), "[boot:%s] %s\n", stage, msg)
				},
			}.Default()
			return o.Boot(cmd.Context())
		},
	}
	c.Flags().StringVar(&identityFile, "identity-file", "/etc/identity.cfg", "path to local identity config (reserved)")
	c.Flags().StringVar(&caFile, "ca-file", "", "platform CA bundle (reserved; passed via initramfs)")
	c.Flags().StringVar(&bootstrapTok, "bootstrap-token", "", "single-use enrollment token (reserved override)")
	c.Flags().StringVar(&pkiDir, "pki-dir", enroll.PKIDir, "directory to persist enrollment PKI material")
	c.Flags().BoolVar(&dryRun, "dry-run", false, "print plan without executing mounts or switch_root")
	return c
}

// --- service -----------------------------------------------------------------
func serviceCmd() *cobra.Command {
	var (
		platformURL       string
		heartbeatInterval time.Duration
		pkiDir            string
		a2aListen         string
		a2aInference      string
		isolationRuntimes []string
	)
	c := &cobra.Command{
		Use:   "service",
		Short: "Long-lived agent loop (heartbeat, task lease, cert rotation)",
		RunE: func(cmd *cobra.Command, args []string) error {
			// Env fallbacks: provisioned nodes configure the agent through
			// module environment, not hand-typed flags. A set flag always
			// wins over the env var (cobra has already parsed it here).
			a2aListen = envOr(a2aListen, "POWERNODE_A2A_LISTEN")
			a2aInference = envOr(a2aInference, "POWERNODE_A2A_INFERENCE")
			if len(isolationRuntimes) == 0 {
				isolationRuntimes = splitCSV(os.Getenv("POWERNODE_ISOLATION_RUNTIMES"))
			}
			svc := runtime.New(runtime.Config{
				PlatformURL:          platformURL,
				AgentVersion:         Version,
				HeartbeatInterval:    heartbeatInterval,
				PKIDir:               pkiDir,
				A2AListenAddr:        a2aListen,
				A2AInferenceEndpoint: a2aInference,
				IsolationRuntimes:    isolationRuntimes,
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
	// AI/MCP workload substrate (L2.5/L3 + L0). Default-OFF: the A2A server
	// starts only when a listen address is configured (flag or
	// POWERNODE_A2A_LISTEN). The inference endpoint enables the inference.*
	// peer skills; isolation runtimes (e.g. "gvisor") are provisioned on the
	// docker daemon before it starts.
	c.Flags().StringVar(&a2aListen, "a2a-listen", "", "agent-to-agent MCP server listen address, e.g. :7777 (env POWERNODE_A2A_LISTEN; empty = disabled)")
	c.Flags().StringVar(&a2aInference, "a2a-inference", "", "local inference runtime endpoint for A2A inference.* skills, e.g. http://127.0.0.1:11434 (env POWERNODE_A2A_INFERENCE)")
	c.Flags().StringSliceVar(&isolationRuntimes, "isolation-runtime", nil, "isolation runtimes to provision on the docker daemon, e.g. gvisor (repeatable; env POWERNODE_ISOLATION_RUNTIMES=comma,sep)")
	// --platform-url is intentionally NOT required: the agent self-bootstraps
	// from identity (kernel cmdline / virtio-fw-cfg / cloud metadata). Pass
	// the flag only when the operator wants to override the discovered URL.
	return c
}

// envOr returns flagVal when it's non-empty, otherwise the value of the named
// environment variable. Lets a set flag win over an env fallback.
func envOr(flagVal, envKey string) string {
	if flagVal != "" {
		return flagVal
	}
	return os.Getenv(envKey)
}

// splitCSV parses a comma-separated env value into a trimmed, non-empty slice.
// Returns nil for an empty string (so callers can treat "unset" uniformly).
func splitCSV(v string) []string {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	var out []string
	for _, part := range strings.Split(v, ",") {
		if p := strings.TrimSpace(part); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// --- a2a-call ----------------------------------------------------------------
// a2aCallCmd is the operator/diagnostic entrypoint for agent-to-agent (A2A)
// calls. It loads THIS node's enrolled mTLS identity from --pki-dir, presents a
// platform-minted capability token, and invokes a skill on a peer instance's
// A2A server. This is the first consumer of internal/a2a's client — the same
// a2a.Client path a mission-driven peer call uses, exposed for reachability
// testing (the A2A analogue of a ping). The peer's server cert is verified
// against the platform's *issuing* chain (ca-chain.crt) — the same trust root
// the A2A server presents — so mutual verification closes both ways.
func a2aCallCmd() *cobra.Command {
	var (
		peerURL   string
		tokenFile string
		skill     string
		argsJSON  string
		pkiDir    string
		timeout   time.Duration
	)
	c := &cobra.Command{
		Use:   "a2a-call",
		Short: "Invoke a skill on a peer instance's A2A server (mTLS + capability token)",
		RunE: func(cmd *cobra.Command, args []string) error {
			if peerURL == "" || skill == "" || tokenFile == "" {
				return errors.New("a2a-call requires --peer-url, --skill, and --token-file")
			}
			paths := enroll.PathsUnder(pkiDir)
			cert, err := tls.LoadX509KeyPair(paths.Cert, paths.Key)
			if err != nil {
				return fmt.Errorf("load node identity from %s (run `enroll` first?): %w", pkiDir, err)
			}
			pool, err := certPoolFromFile(paths.CAChain)
			if err != nil {
				return err
			}
			tok, err := loadCapabilityToken(tokenFile)
			if err != nil {
				return err
			}
			var argv any
			if strings.TrimSpace(argsJSON) != "" {
				if err := json.Unmarshal([]byte(argsJSON), &argv); err != nil {
					return fmt.Errorf("parse --args JSON: %w", err)
				}
			}
			httpClient := &http.Client{
				Timeout:   timeout,
				Transport: &http.Transport{TLSClientConfig: a2a.ClientTLSConfig(cert, pool)},
			}
			res, err := a2a.NewClient(httpClient).CallSkill(peerURL, tok, skill, argv)
			if err != nil {
				return fmt.Errorf("a2a call %q -> %s: %w", skill, peerURL, err)
			}
			fmt.Println(string(res))
			return nil
		},
	}
	c.Flags().StringVar(&peerURL, "peer-url", "", "peer A2A base URL, e.g. https://[overlay]:7777 (required)")
	c.Flags().StringVar(&tokenFile, "token-file", "", "JSON file with the platform-minted capability token {envelope, signature} (required)")
	c.Flags().StringVar(&skill, "skill", "", "skill/tool name to invoke, e.g. inference.ping (required)")
	c.Flags().StringVar(&argsJSON, "args", "", "skill arguments as a JSON object")
	c.Flags().StringVar(&pkiDir, "pki-dir", enroll.PKIDir, "directory with this node's node.crt/node.key/ca-chain.crt")
	c.Flags().DurationVar(&timeout, "timeout", 15*time.Second, "call timeout")
	return c
}

// certPoolFromFile loads a PEM CA bundle into an x509 pool.
func certPoolFromFile(path string) (*x509.CertPool, error) {
	caPEM, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read ca chain %s: %w", path, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, fmt.Errorf("ca chain %s has no parseable certs", path)
	}
	return pool, nil
}

// loadCapabilityToken reads a platform-minted capability token file. It accepts
// either the bare wire shape {envelope, signature} or the richer mint payload
// (same two fields plus advisory handle/sub/aud/skill metadata) — only
// envelope+signature travel over the wire; the callee verifies offline against
// the advertised signing key.
func loadCapabilityToken(path string) (*a2a.Token, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read token file %s: %w", path, err)
	}
	var t a2a.Token
	if err := json.Unmarshal(b, &t); err != nil {
		return nil, fmt.Errorf("parse token file %s: %w", path, err)
	}
	if t.Envelope == "" || t.Signature == "" {
		return nil, fmt.Errorf("token file %s missing envelope/signature", path)
	}
	return &t, nil
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
//
//	/run/powernode/modules                 (9p share, ro)
//	/run/powernode/overlay/{upper,work}    (tmpfs scratch)
//	/sysroot                               (overlayfs union)
//	  /sysroot/persist  ← bind /persist (PKI + agent state survive pivot)
//	  /sysroot/dev      ← rbind /dev
//	  /sysroot/sys      ← rbind /sys
//	  /sysroot/proc     ← rbind /proc
//	  /sysroot/run      ← rbind /run    (lets agent in new root see fw-cfg /
//	                                     9p share without remounting)
//
// Caller (typically powernode-mount.service) follows up with
//
//	systemctl switch-root /sysroot /sbin/init
//
// which kills the initramfs systemd and re-execs in the new rootfs.
func prepareRootCmd() *cobra.Command {
	var (
		source        string
		modulesSource string
		sysroot       string
		modules       []string
		ninePTag      string
	)
	c := &cobra.Command{
		Use:   "prepare-root",
		Short: "Mount the module union at /sysroot, ready for switch-root",
		RunE: func(cmd *cobra.Command, args []string) error {
			return dispatchPrepareRoot(source, modulesSource, sysroot, ninePTag, modules)
		},
	}
	c.Flags().StringVar(&source, "source", "9p", "module source: \"oci\" (pull the platform-assigned set + erofs/overlay compose) or \"9p\" (legacy libvirt 9p rootfs share)")
	c.Flags().StringVar(&modulesSource, "modules-source", "/run/powernode/modules", "where the 9p share is mounted (source=9p only)")
	c.Flags().StringVar(&sysroot, "sysroot", "/sysroot", "target mount point for the union")
	c.Flags().StringSliceVar(&modules, "modules", []string{"system-base"}, "module names in priority order, low to high (source=9p only)")
	c.Flags().StringVar(&ninePTag, "9p-tag", "powernode_modules", "9p share tag (source=9p only; must match libvirt <target dir=...>)")
	return c
}

// runPrepareRootOCIFn / runPrepareRoot9pFn are package vars so tests can
// verify --source routing without performing real mounts.
var (
	runPrepareRootOCIFn = runPrepareRootOCI
	runPrepareRoot9pFn  = runPrepareRoot
)

// dispatchPrepareRoot routes prepare-root by --source. "oci" composes the
// real platform-assigned module set (ComposeForPivot) — the direct_kernel/
// UKI path; "9p" (default) is the legacy libvirt 9p rootfs-share path.
func dispatchPrepareRoot(source, modulesSource, sysroot, ninePTag string, modules []string) error {
	switch source {
	case "oci":
		return runPrepareRootOCIFn(sysroot)
	case "9p", "":
		return runPrepareRoot9pFn(modulesSource, sysroot, ninePTag, modules)
	default:
		return fmt.Errorf("prepare-root: unknown --source %q (want \"oci\" or \"9p\")", source)
	}
}

// runPrepareRootOCI composes the module union at sysroot from the platform's
// real NodeModuleAssignment set (queried dynamically, NOT a hardcoded list)
// and leaves it ready for switch-root. It reuses runtime.ComposeForPivot —
// the same pull + cosign/fs-verity verify + erofs loop-mount + overlay-union +
// identity/native-unit render the boot orchestrator uses — then binds the
// durable/API mounts into the union (ComposeForPivot intentionally leaves that
// to the boot/initramfs mount plan). It does NOT re-enroll: enrollment already
// happened (federation-accept + the cert powernode-mount.service gates on);
// the platform URL comes from the enrolled PKI dir, with identity discovery as
// a fallback — the same resolution the long-lived `service` loop uses.
func runPrepareRootOCI(sysroot string) error {
	pkiDir := enroll.ResolveDefaultPKIDir()
	platformURL := enroll.ReadPlatformURL(enroll.PathsUnder(pkiDir))
	if platformURL == "" {
		if ident, err := identity.DefaultResolver().Resolve(context.Background()); err == nil && ident != nil {
			platformURL = ident.PlatformURL
		}
	}
	if platformURL == "" {
		return errors.New("prepare-root --source oci: could not resolve platform URL (enrolled URL empty and identity discovery failed)")
	}
	fmt.Printf("[prepare-root] source=oci platform=%s pki=%s sysroot=%s\n", platformURL, pkiDir, sysroot)

	composer, err := runtime.NewPivotComposer(platformURL, pkiDir, func(stage string, cerr error) {
		fmt.Fprintf(os.Stderr, "[prepare-root:compose:%s] %v\n", stage, cerr)
	})
	if err != nil {
		return fmt.Errorf("build oci pivot composer: %w", err)
	}
	if err := composer.ComposeForPivot(context.Background(), sysroot); err != nil {
		return fmt.Errorf("compose oci module union at %s: %w", sysroot, err)
	}
	return bindAndCheckSysroot(sysroot)
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

	// 6+7. Bind the durable/API mounts into the union + sanity-check init.
	return bindAndCheckSysroot(sysroot)
}

// bindAndCheckSysroot rbind-mounts /persist + the API filesystems into the
// composed union at sysroot (so PKI/agent state + /dev,/sys,/proc,/run survive
// switch-root) and verifies an init exists in the new root. Shared by both
// prepare-root sources (9p + oci). rbind carries submounts (e.g.
// /sys/firmware/qemu_fw_cfg) along.
func bindAndCheckSysroot(sysroot string) error {
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

	initPath, err := ensureCanonicalInit(sysroot)
	if err != nil {
		return err
	}
	fmt.Printf("[prepare-root] OK — init=%s (switch-root via /sbin/init)\n", initPath)
	return nil
}

// ensureCanonicalInit locates the init in the composed root and guarantees a
// canonical /sbin/init that resolves to it, returning init's new-root-absolute
// path. The mount unit's `systemctl switch-root /sysroot /sbin/init`
// chase-validates that exact path and fails the whole unit (→ no pivot) when
// it's absent — and real erofs module rootfs ship systemd only at
// /usr/lib/systemd/systemd with no /sbin/init compat symlink. Synthesizing the
// link here makes switch-root layout-agnostic. The returned/target path is
// new-root-absolute (leading "/") because /sysroot becomes / after the pivot.
func ensureCanonicalInit(sysroot string) (string, error) {
	rels := []string{"sbin/init", "lib/systemd/systemd", "usr/lib/systemd/systemd"}
	for _, rel := range rels {
		if _, err := os.Stat(filepath.Join(sysroot, rel)); err != nil {
			continue
		}
		if rel == "sbin/init" {
			return "/sbin/init", nil
		}
		// Materialising /sbin as a DIRECTORY here is what broke usr-merge on every
		// composed node. Ubuntu ships /sbin as a symlink to usr/sbin; /bin, /lib and
		// /lib64 survive as symlinks precisely because nothing mkdir's them, while
		// this MkdirAll ran on every boot and turned /sbin into a real directory
		// containing only init. Everything else in /usr/sbin then vanished from
		// /sbin — 1 entry visible against 170 — silently breaking anything that
		// resolves a binary by its /sbin path. Two such consumers were found on
		// ops-hub: qemu-ga's guest-shutdown execs /sbin/shutdown (so the node could
		// never be shut down gracefully) and the kernel's usermode helper execs
		// /sbin/modprobe (so request_module autoloading failed fleet-wide).
		//
		// Preserve the merge instead: when /sbin is absent, create it AS the
		// symlink, and let the init link land in usr/sbin through it. switch-root
		// chases /sbin/init → /usr/sbin/init → the real systemd, so the contract it
		// validates still holds. A pre-existing real /sbin (non-usr-merged distro,
		// or a module that legitimately ships one) is left exactly as it was.
		if err := ensureSbin(sysroot); err != nil {
			return "", err
		}
		sbinInit := filepath.Join(sysroot, "sbin/init")
		// Clear any pre-existing (possibly dangling) entry so Symlink won't EEXIST.
		_ = os.Remove(sbinInit)
		target := "/" + rel
		if err := os.Symlink(target, sbinInit); err != nil {
			return "", fmt.Errorf("symlink /sbin/init -> %s: %w", target, err)
		}
		return target, nil
	}
	return "", fmt.Errorf("no init found in %s (tried %v)", sysroot, rels)
}

// ensureSbin guarantees a usable /sbin under sysroot WITHOUT destroying
// usr-merge. Ubuntu's /sbin is a symlink to usr/sbin; creating a real directory
// there shadows every binary in /usr/sbin for anything that resolves by /sbin
// path. Order of preference:
//
//   - /sbin already exists (symlink or directory) → leave it alone. A real
//     directory here is legitimate on non-usr-merged layouts.
//   - /usr/sbin exists → create /sbin as a RELATIVE symlink to usr/sbin, matching
//     what the distro itself ships. Relative (not "/usr/sbin") so it resolves
//     correctly both now, under the /sysroot prefix, and after the pivot.
//   - otherwise → fall back to a real directory, which is all we can do.
func ensureSbin(sysroot string) error {
	sbin := filepath.Join(sysroot, "sbin")
	if _, err := os.Lstat(sbin); err == nil {
		return nil // exists as symlink or dir — do not disturb it
	}
	if st, err := os.Stat(filepath.Join(sysroot, "usr", "sbin")); err == nil && st.IsDir() {
		if err := os.Symlink("usr/sbin", sbin); err == nil {
			return nil
		}
		// Fall through to mkdir on symlink failure — a working boot beats a tidy
		// layout, and switch-root only needs /sbin/init to resolve.
	}
	if err := os.MkdirAll(sbin, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", sbin, err)
	}
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

// --- persist-prepare (#69: disk-backed /persist) ----------------------------
//
// The boot disk image bakes an ext4 partition labeled "persist" (see the
// disk-image build script) intended to hold PKI + module cache across reboots.
// It ships small; this grows it to a bounded target on first boot so the mTLS
// identity and OCI cache survive power cycles (claim-by-id is single-bind — a
// wiped cert can't re-claim). Runs in the initramfs BEFORE persist.mount, which
// does the actual mount. Grow-only + idempotent: a no-op once already sized.

// Injectable seams — unit tests stub these so the grow-decision logic is
// exercised without touching real block devices.
var (
	persistLookupLabelFn    = lookupDeviceByLabel
	persistPartitionBytesFn = blockDeviceBytes
	persistRunFn            = runCmdWithStdin
	persistWaitForLabelFn   = waitForLabel
	persistIsMountedFn      = isMountedAt
)

// persistDefaultSizeGB is the bounded target for /persist, overridable via
// POWERNODE_PERSIST_SIZE_GB. Bounded (not grow-to-fill) so later increments can
// carve additional volumes from the same boot disk; 12G is ample over today's
// ~1GB module cache + tiny PKI, with headroom for module growth.
func persistDefaultSizeGB() int {
	if v := strings.TrimSpace(os.Getenv("POWERNODE_PERSIST_SIZE_GB")); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return 12
}

func persistPrepareCmd() *cobra.Command {
	var (
		label  string
		sizeGB int
	)
	c := &cobra.Command{
		Use:   "persist-prepare",
		Short: "Grow the persist partition to a bounded size (idempotent, pre-mount)",
		Long: `Grows the boot disk's baked persist partition (ext4, label "persist") to a
bounded target size on first boot, then no-ops on every subsequent boot. Runs
in the initramfs before persist.mount; it only resizes — persist.mount mounts.
If no persist-labeled partition exists, it's a silent no-op (the tmpfs fallback
mount applies).`,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runPersistPrepare(label, sizeGB)
		},
	}
	c.Flags().StringVar(&label, "label", "persist", "filesystem label of the persist partition")
	c.Flags().IntVar(&sizeGB, "size-gb", persistDefaultSizeGB(), "bounded target size in GB (env POWERNODE_PERSIST_SIZE_GB)")
	return c
}

func runPersistPrepare(label string, targetGB int) error {
	if targetGB <= 0 {
		targetGB = persistDefaultSizeGB()
	}
	dev, err := persistLookupLabelFn(label)
	if err != nil {
		return fmt.Errorf("persist-prepare: look up label %q: %w", label, err)
	}
	if dev == "" {
		fmt.Printf("[persist-prepare] no partition labeled %q — skipping (tmpfs fallback applies)\n", label)
		return nil
	}
	curBytes, err := persistPartitionBytesFn(dev)
	if err != nil {
		return fmt.Errorf("persist-prepare: size of %s: %w", dev, err)
	}
	targetBytes := int64(targetGB) * 1024 * 1024 * 1024
	if curBytes >= targetBytes {
		fmt.Printf("[persist-prepare] %s already %.1fG (>= %dG target) — no-op\n",
			dev, float64(curBytes)/(1024*1024*1024), targetGB)
		return nil
	}
	disk, partNum, err := splitPartitionDevice(dev)
	if err != nil {
		return fmt.Errorf("persist-prepare: %w", err)
	}
	fmt.Printf("[persist-prepare] growing %s (partition %d of %s) to %dG\n", dev, partNum, disk, targetGB)

	// Resize the PARTITION in place: empty start keeps the existing start sector,
	// absolute "<N>G" sets a deterministic (idempotent) size. --no-reread avoids
	// the BLKRRPART that fails on a busy disk; partx -u refreshes the kernel view.
	spec := fmt.Sprintf(", %dG\n", targetGB)
	if err := persistRunFn("sfdisk", spec, "--no-reread", "--force", "-N", strconv.Itoa(partNum), disk); err != nil {
		return fmt.Errorf("persist-prepare: sfdisk resize %s part %d: %w", disk, partNum, err)
	}
	if err := persistRunFn("partx", "", "-u", disk); err != nil {
		// Non-fatal: some kernels already reflect the new size. resize2fs will
		// fail loudly below if the device size genuinely didn't update.
		fmt.Fprintf(os.Stderr, "[persist-prepare] partx -u %s: %v (continuing)\n", disk, err)
	}
	// Grow the filesystem to fill the enlarged partition.
	if err := persistRunFn("resize2fs", "", dev); err != nil {
		return fmt.Errorf("persist-prepare: resize2fs %s: %w", dev, err)
	}
	fmt.Printf("[persist-prepare] OK — %s grown to %dG\n", dev, targetGB)
	return nil
}

// splitPartitionDevice splits a partition device into its parent disk and
// 1-based partition number: /dev/sda2 -> (/dev/sda, 2); /dev/nvme0n1p2 ->
// (/dev/nvme0n1, 2); /dev/mmcblk0p1 -> (/dev/mmcblk0, 1).
func splitPartitionDevice(dev string) (disk string, partNum int, err error) {
	i := len(dev)
	for i > 0 && dev[i-1] >= '0' && dev[i-1] <= '9' {
		i--
	}
	if i == len(dev) || i == 0 {
		return "", 0, fmt.Errorf("cannot parse partition number from %q", dev)
	}
	n, err := strconv.Atoi(dev[i:])
	if err != nil {
		return "", 0, fmt.Errorf("bad partition number in %q: %w", dev, err)
	}
	base := dev[:i]
	// nvme/mmc style: the base ends in "<digit>p"; strip the separator "p".
	if strings.HasSuffix(base, "p") && len(base) >= 2 && base[len(base)-2] >= '0' && base[len(base)-2] <= '9' {
		base = base[:len(base)-1]
	}
	return base, n, nil
}

func lookupDeviceByLabel(label string) (string, error) {
	out, err := exec.Command("blkid", "-L", label).Output()
	if err != nil {
		// blkid exits 2 when the label isn't found — treat as "absent", not error.
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 2 {
			return "", nil
		}
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func blockDeviceBytes(dev string) (int64, error) {
	out, err := exec.Command("blockdev", "--getsize64", dev).Output()
	if err != nil {
		return 0, err
	}
	return strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
}

func runCmdWithStdin(name, stdin string, args ...string) error {
	cmd := exec.Command(name, args...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%s: %w (output: %s)", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// persistSetupCmd is the race-free /persist bring-up: one oneshot invocation
// that WAITS for udev to settle, then decides once — disk-backed ext4 when the
// persist label resolves, tmpfs fallback when it doesn't. It replaces the
// earlier persist.mount + persist-grow.service + persist-fallback.service trio,
// whose one-shot ConditionPathExists= checks raced udev (the negated fallback
// condition could tmpfs-mount /persist before the by-label symlink appeared,
// then persist.mount was skipped as "already a mountpoint").
func persistSetupCmd() *cobra.Command {
	var (
		label      string
		mountPoint string
		sizeGB     int
	)
	c := &cobra.Command{
		Use:   "persist-setup",
		Short: "Wait for udev, then mount /persist (disk-backed ext4, else tmpfs)",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runPersistSetup(label, mountPoint, sizeGB)
		},
	}
	c.Flags().StringVar(&label, "label", "persist", "filesystem label of the persist partition")
	c.Flags().StringVar(&mountPoint, "mount", "/persist", "mount point")
	c.Flags().IntVar(&sizeGB, "size-gb", persistDefaultSizeGB(), "bounded ext4 target size in GB (env POWERNODE_PERSIST_SIZE_GB)")
	return c
}

// persistTmpfsSizeArg is the size cap for the tmpfs fallback (RAM-backed; only
// used when there's no persist partition — physical/edge images predating the
// layout). Matches the disk target so behavior is predictable either way.
const persistTmpfsSizeArg = "mode=0755,size=4G"

func runPersistSetup(label, mountPoint string, targetGB int) error {
	if mountPoint == "" {
		mountPoint = "/persist"
	}
	if persistIsMountedFn(mountPoint) {
		fmt.Printf("[persist-setup] %s already mounted — no-op\n", mountPoint)
		return nil
	}
	// Block until udev has settled so the by-label symlink is present if the
	// partition exists at all. This is the whole point: a single decision AFTER
	// the wait, so neither the disk path nor the fallback can race udev.
	dev := persistWaitForLabelFn(label)
	if dev != "" {
		if err := runPersistPrepare(label, targetGB); err != nil {
			// Grow is best-effort; still mount the (unresized) partition so PKI +
			// cache land on real disk rather than falling back to tmpfs.
			fmt.Fprintf(os.Stderr, "[persist-setup] grow failed (mounting anyway): %v\n", err)
		}
		if err := persistRunFn("mount", "", "-t", "ext4", "-o", "rw,noatime", dev, mountPoint); err != nil {
			return fmt.Errorf("persist-setup: mount ext4 %s at %s: %w", dev, mountPoint, err)
		}
		fmt.Printf("[persist-setup] OK — %s (ext4, disk-backed) at %s\n", dev, mountPoint)
		return nil
	}
	// No persist partition: tmpfs fallback (not reboot-surviving).
	if err := persistRunFn("mount", "", "-t", "tmpfs", "-o", persistTmpfsSizeArg, "tmpfs", mountPoint); err != nil {
		return fmt.Errorf("persist-setup: tmpfs fallback at %s: %w", mountPoint, err)
	}
	fmt.Printf("[persist-setup] no %q partition — tmpfs fallback at %s\n", label, mountPoint)
	return nil
}

// waitForLabel blocks until udev has processed coldplug (so by-label symlinks
// exist for present devices), then resolves the label. Returns "" if no such
// partition exists. `udevadm settle` drains the udev queue; the follow-up poll
// covers kernels/initramfs where settle returns before the symlink is linked.
func waitForLabel(label string) string {
	_ = exec.Command("udevadm", "settle", "--timeout=20").Run()
	if dev, _ := lookupDeviceByLabel(label); dev != "" {
		return dev
	}
	for i := 0; i < 10; i++ {
		time.Sleep(time.Second)
		if dev, _ := lookupDeviceByLabel(label); dev != "" {
			return dev
		}
	}
	return ""
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
	var (
		bundlePath     string
		digest         string
		identityRegexp string
		issuerRegexp   string
		jsonOut        bool
	)
	c := &cobra.Command{
		Use:   "verify <module-path>",
		Short: "Verify cosign signature + fs-verity hash on a local module artifact",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			res, runErr := agentcli.RunVerify(cmd.Context(), agentcli.VerifyOptions{
				ModulePath:     args[0],
				BundlePath:     bundlePath,
				Digest:         digest,
				IdentityRegexp: identityRegexp,
				IssuerRegexp:   issuerRegexp,
				JSON:           jsonOut,
			})
			return renderCLI(cmd, res, runErr, jsonOut)
		},
	}
	c.Flags().StringVar(&bundlePath, "bundle", "", "cosign bundle path (default: <module>.cosign-bundle)")
	c.Flags().StringVar(&digest, "digest", "", "expected fs-verity digest (sha256 hex)")
	c.Flags().StringVar(&identityRegexp, "identity-regexp", "", "cosign cert identity regex (Sigstore Fulcio identity pinning)")
	c.Flags().StringVar(&issuerRegexp, "issuer-regexp", "", "cosign cert OIDC issuer regex")
	c.Flags().BoolVar(&jsonOut, "json", false, "emit JSON output instead of human-readable lines")
	return c
}

// --- introspect --------------------------------------------------------------
//
// Diagnostic snapshot of the agent's own state — identity, enrolled
// certificate, module mounts, agent binary version. Read-only; no platform
// API call. Useful when SSH'd into a node to answer "what does this agent
// think it is?" without trusting the platform's view.
func introspectCmd() *cobra.Command {
	var pkiDir string
	c := &cobra.Command{
		Use:   "introspect",
		Short: "Print the agent's view of itself (identity, modules, certs, mounts)",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Printf("powernode-agent %s\n", Version)
			fmt.Println()

			fmt.Println("─── identity ───")
			printIdentitySnapshot()
			fmt.Println()

			fmt.Println("─── PKI ───")
			printPKISnapshot(pkiDir)
			fmt.Println()

			fmt.Println("─── modules ───")
			printModulesSnapshot()
			fmt.Println()

			fmt.Println("─── relevant mounts ───")
			printRelevantMounts()
			return nil
		},
	}
	c.Flags().StringVar(&pkiDir, "pki-dir", enroll.PKIDir, "directory containing node.crt/node.key/ca-bundle.crt")
	return c
}

// printIdentitySnapshot reports the discovered identity fields. Reads
// /etc/identity.cfg directly rather than re-running cloud probes — those
// probes are expensive and the cached identity from boot is what the
// service is actually using.
func printIdentitySnapshot() {
	candidates := []string{"/etc/identity.cfg", "/persist/etc/identity.cfg", "/boot/identity.cfg"}
	var data []byte
	var src string
	for _, p := range candidates {
		if b, err := os.ReadFile(p); err == nil {
			data = b
			src = p
			break
		}
	}
	if src == "" {
		fmt.Println("  identity.cfg: (none found)")
		return
	}
	fmt.Printf("  source:         %s\n", src)
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		val = strings.Trim(strings.TrimSpace(val), `"`)
		// Redact the bootstrap token — it's single-use, but mirroring it to
		// stdout still leaks an enrollment capability.
		if strings.EqualFold(key, "bootstrap_token") || strings.EqualFold(key, "BOOTSTRAP_TOKEN") {
			val = redact(val)
		}
		fmt.Printf("  %-15s %s\n", key+":", val)
	}
}

// printPKISnapshot reads the enrolled cert (if present) and reports its
// subject, issuer, validity window, and remaining lifetime. Does NOT decode
// the private key — the file's existence is enough; reading it would risk
// leaking material into a debug log.
func printPKISnapshot(pkiDir string) {
	paths := enroll.PathsUnder(pkiDir)
	fmt.Printf("  pki-dir:        %s\n", pkiDir)

	keyInfo, err := os.Stat(paths.Key)
	if err == nil {
		fmt.Printf("  node.key:       present (mode=%o, %d bytes)\n", keyInfo.Mode().Perm(), keyInfo.Size())
	} else {
		fmt.Println("  node.key:       (not found — agent has not enrolled)")
	}

	certPEM, err := os.ReadFile(paths.Cert)
	if err != nil {
		fmt.Println("  node.crt:       (not found — agent has not enrolled)")
		return
	}
	block, _ := pem.Decode(certPEM)
	if block == nil {
		fmt.Println("  node.crt:       present but PEM decode failed")
		return
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		fmt.Printf("  node.crt:       parse error: %v\n", err)
		return
	}
	now := time.Now()
	fmt.Printf("  node.crt:\n")
	fmt.Printf("    subject:      %s\n", cert.Subject.String())
	fmt.Printf("    issuer:       %s\n", cert.Issuer.String())
	fmt.Printf("    not_before:   %s\n", cert.NotBefore.UTC().Format(time.RFC3339))
	fmt.Printf("    not_after:    %s\n", cert.NotAfter.UTC().Format(time.RFC3339))
	switch {
	case now.Before(cert.NotBefore):
		fmt.Printf("    validity:     not yet valid (begins %s)\n", cert.NotBefore.UTC().Format(time.RFC3339))
	case now.After(cert.NotAfter):
		fmt.Printf("    validity:     EXPIRED %s ago\n", roundDuration(now.Sub(cert.NotAfter)))
	default:
		fmt.Printf("    validity:     valid (expires in %s)\n", roundDuration(cert.NotAfter.Sub(now)))
	}
}

// redact returns a fixed-width mask, preserving the value's length-bucket
// signal (so an empty token shows differently from a populated one).
func redact(s string) string {
	if s == "" {
		return "(empty)"
	}
	return fmt.Sprintf("(redacted, %d chars)", len(s))
}

// roundDuration trims a Duration to second precision for log readability.
func roundDuration(d time.Duration) time.Duration {
	if d > 24*time.Hour {
		return d.Round(time.Hour)
	}
	if d > time.Hour {
		return d.Round(time.Minute)
	}
	return d.Round(time.Second)
}

// --- attach / detach ---------------------------------------------------------
func attachCmd() *cobra.Command {
	var (
		platformURL string
		pkiDir      string
		dryRun      bool
		jsonOut     bool
	)
	c := &cobra.Command{
		Use:   "attach <module-id>",
		Short: "Mount a module into the union (legacy ipn -a)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			res, runErr := agentcli.RunAttach(cmd.Context(), agentcli.AttachOptions{
				ModuleID:    args[0],
				PlatformURL: platformURL,
				PKIDir:      pkiDir,
				DryRun:      dryRun,
				JSON:        jsonOut,
			})
			return renderCLI(cmd, res, runErr, jsonOut)
		},
	}
	c.Flags().StringVar(&platformURL, "platform-url", "", "platform base URL (defaults to identity-discovered)")
	c.Flags().StringVar(&pkiDir, "pki-dir", "", "agent PKI directory (default: /persist/var/lib/powernode/pki)")
	c.Flags().BoolVar(&dryRun, "dry-run", false, "print planned actions without executing")
	c.Flags().BoolVar(&jsonOut, "json", false, "emit JSON output instead of human-readable lines")
	return c
}

func detachCmd() *cobra.Command {
	var (
		platformURL string
		pkiDir      string
		dryRun      bool
		jsonOut     bool
	)
	c := &cobra.Command{
		Use:   "detach <module-id>",
		Short: "Unmount a module from the union (legacy ipn -d)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			res, runErr := agentcli.RunDetach(cmd.Context(), agentcli.DetachOptions{
				ModuleID:    args[0],
				PlatformURL: platformURL,
				PKIDir:      pkiDir,
				DryRun:      dryRun,
				JSON:        jsonOut,
			})
			return renderCLI(cmd, res, runErr, jsonOut)
		},
	}
	c.Flags().StringVar(&platformURL, "platform-url", "", "platform base URL (defaults to identity-discovered)")
	c.Flags().StringVar(&pkiDir, "pki-dir", "", "agent PKI directory (default: /persist/var/lib/powernode/pki)")
	c.Flags().BoolVar(&dryRun, "dry-run", false, "print planned actions without executing")
	c.Flags().BoolVar(&jsonOut, "json", false, "emit JSON output instead of human-readable lines")
	return c
}

// --- update / commit / status / exec / sync / init / volume-setup / puppet ---
func updateCmd() *cobra.Command {
	var (
		platformURL string
		pkiDir      string
		dryRun      bool
		jsonOut     bool
	)
	c := &cobra.Command{
		Use:   "update",
		Short: "Reconcile assignments from /node_api/modules (legacy ipn -u)",
		RunE: func(cmd *cobra.Command, args []string) error {
			res, runErr := agentcli.RunUpdate(cmd.Context(), agentcli.UpdateOptions{
				PlatformURL: platformURL,
				PKIDir:      pkiDir,
				DryRun:      dryRun,
				JSON:        jsonOut,
			})
			return renderCLI(cmd, res, runErr, jsonOut)
		},
	}
	c.Flags().StringVar(&platformURL, "platform-url", "", "platform base URL (defaults to identity-discovered)")
	c.Flags().StringVar(&pkiDir, "pki-dir", "", "agent PKI directory (default: /persist/var/lib/powernode/pki)")
	c.Flags().BoolVar(&dryRun, "dry-run", false, "print planned actions without executing")
	c.Flags().BoolVar(&jsonOut, "json", false, "emit JSON output instead of human-readable lines")
	return c
}

// upgradeBootImageCmd is the manual/debug entry point for an in-place boot-image
// (UKI) upgrade (campaign 019f505f increment 2). The normal path is the
// platform-dispatched `upgrade_boot_image` task; this command drives the same
// bootupgrade.Apply with explicit flags so an operator can upgrade a node by
// hand. It pulls + cosign-verifies the UKI and writes the ESP; it reboots only
// with --reboot.
func upgradeBootImageCmd() *cobra.Command {
	var (
		platformURL, pkiDir                   string
		downloadPath, targetGitSHA, ukiSHA256 string
		cosignPubKeyFile, bundleFile          string
		doReboot                              bool
	)
	c := &cobra.Command{
		Use:   "upgrade-boot-image",
		Short: "In-place UKI boot-image upgrade: pull + cosign-verify + write ESP (manual/debug)",
		RunE: func(cmd *cobra.Command, args []string) error {
			cctx, err := agentcli.BuildContext(platformURL, pkiDir)
			if err != nil {
				return err
			}
			bundle, err := os.ReadFile(bundleFile)
			if err != nil {
				return fmt.Errorf("read cosign bundle: %w", err)
			}
			pubKey, err := os.ReadFile(cosignPubKeyFile)
			if err != nil {
				return fmt.Errorf("read cosign public key: %w", err)
			}
			_, err = bootupgrade.Apply(cmd.Context(), bootupgrade.Deps{
				Runner: mount.ExecRunner{},
				Client: cctx.Transport,
			}, bootupgrade.Options{
				TargetGitSHA:    targetGitSHA,
				UkiSha256:       ukiSHA256,
				CosignPublicKey: string(pubKey),
				CosignBundleB64: base64.StdEncoding.EncodeToString(bundle),
				DownloadPath:    downloadPath,
			})
			if err != nil {
				return err
			}
			// Apply records the pending slot itself, under bootMu and before arming
			// the one-shot. It used to be done here instead, which left a window
			// where a crash after arming but before recording booted the new slot
			// with nothing marking it pending — it then never blessed and silently
			// reverted when the boot counter ran out (observed in RCP v2 P0-b).
			fmt.Fprintln(cmd.OutOrStdout(), "boot image written + cosign-verified")
			if doReboot {
				fmt.Fprintln(cmd.OutOrStdout(), "rebooting into the new image…")
				return mount.ExecRunner{}.Run(cmd.Context(), "systemctl", "reboot")
			}
			fmt.Fprintln(cmd.OutOrStdout(), "not rebooting (pass --reboot to boot the new image)")
			return nil
		},
	}
	c.Flags().StringVar(&platformURL, "platform-url", "", "platform base URL (default: identity-discovered)")
	c.Flags().StringVar(&pkiDir, "pki-dir", "", "agent PKI directory (default: /persist/var/lib/powernode/pki)")
	c.Flags().StringVar(&downloadPath, "download-path", "/api/v1/system/node_api/boot_image/download", "node_api path to GET the UKI")
	c.Flags().StringVar(&targetGitSHA, "target-git-sha", "", "git_sha the new UKI will report on its kernel cmdline. NOT informational: "+
		"it is persisted as the pending target and the post-reboot confirm compares the booted sha against it. "+
		"A wrong value makes the confirm see a mismatch and abandon the upgrade, silently reverting at the next reboot")
	c.Flags().StringVar(&ukiSHA256, "uki-sha256", "", "expected UKI sha256 (required)")
	c.Flags().StringVar(&cosignPubKeyFile, "cosign-public-key-file", "", "path to the platform's cosign public key (required)")
	c.Flags().StringVar(&bundleFile, "cosign-bundle-file", "", "path to the UKI cosign bundle (required)")
	c.Flags().BoolVar(&doReboot, "reboot", false, "reboot into the new image after a successful write")
	return c
}

func commitCmd() *cobra.Command {
	var (
		platformURL string
		pkiDir      string
		changelog   string
		pushPath    string
		autoPush    bool
		scanSecrets bool
		jsonOut     bool
		sourceRoot  string
		stagingRoot string
	)
	c := &cobra.Command{
		Use:   "commit <module-id>",
		Short: "Capture live delta + stage (or push) as new module version (legacy ipn -c)",
		Long: `Default behavior is stage-only: captures the upper-dir delta to
/persist/var/lib/powernode/commits/<id>/<ts>.tar.zst and prints the path. Operator
inspects, then explicitly --push <path> to upload. Use --auto-push to capture +
upload in one step (forces --scan-secrets ON).`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			res, runErr := agentcli.RunCommit(cmd.Context(), agentcli.CommitOptions{
				ModuleID:    args[0],
				Changelog:   changelog,
				PushPath:    pushPath,
				AutoPush:    autoPush,
				ScanSecrets: scanSecrets,
				JSON:        jsonOut,
				PlatformURL: platformURL,
				PKIDir:      pkiDir,
				SourceRoot:  sourceRoot,
				StagingRoot: stagingRoot,
			})
			return renderCLI(cmd, res, runErr, jsonOut)
		},
	}
	c.Flags().StringVar(&platformURL, "platform-url", "", "platform base URL (defaults to identity-discovered)")
	c.Flags().StringVar(&pkiDir, "pki-dir", "", "agent PKI directory")
	c.Flags().StringVar(&changelog, "changelog", "", "operator-supplied description of what this commit captures")
	c.Flags().StringVar(&pushPath, "push", "", "path to a previously-staged tarball to upload (skips capture)")
	c.Flags().BoolVar(&autoPush, "auto-push", false, "capture + push in one step (forces --scan-secrets ON)")
	c.Flags().BoolVar(&scanSecrets, "scan-secrets", false, "scan staged tree for credential patterns; refuse on hits")
	c.Flags().StringVar(&sourceRoot, "source-root", "", "rsync source root (default /sysroot)")
	c.Flags().StringVar(&stagingRoot, "staging-root", "", "where staged tarballs land (default /persist/var/lib/powernode/commits)")
	c.Flags().BoolVar(&jsonOut, "json", false, "emit JSON output")
	return c
}

// statusCmd prints which modules are present in the 9p share + which are
// currently composed into the overlay union. "Attached" = the module's
// rootfs is one of the overlay's lowerdirs (i.e. its files are visible in
// the running root). "Available" = present in the share but not active.
//
// Read-only: walks /run/powernode/modules and parses /proc/mounts. Doesn't
// hit the platform — answers "what's actually mounted right now" without
// trusting the platform's expected-state view.
func statusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Print attach/detach state of all modules (legacy ipn -s)",
		RunE: func(cmd *cobra.Command, args []string) error {
			printModulesSnapshot()
			return nil
		},
	}
}

// printModulesSnapshot enumerates modules in the 9p share and marks each as
// attached if it's in the overlay's lowerdir list.
func printModulesSnapshot() {
	const moduleRoot = "/run/powernode/modules"
	entries, err := os.ReadDir(moduleRoot)
	if err != nil {
		fmt.Printf("  (cannot read %s: %v)\n", moduleRoot, err)
		return
	}

	attached := overlayLowerdirs()
	attachedSet := make(map[string]struct{}, len(attached))
	// mountOrder records the lowerdir position of each attached module
	// dir — index 0 is the TOP of the overlay stack (highest effective
	// priority, kernel resolves its content first). The agent's overlay
	// composer renders lowerdirs in priority-descending order so this
	// is also the platform-priority-descending order.
	mountOrder := make(map[string]int, len(attached))
	for i, p := range attached {
		// Each lowerdir entry is "<moduleRoot>/<name>/rootfs"; pull <name>.
		rel, err := filepath.Rel(moduleRoot, p)
		if err != nil {
			continue
		}
		parts := strings.SplitN(rel, string(filepath.Separator), 2)
		if len(parts) >= 1 && parts[0] != "" {
			attachedSet[parts[0]] = struct{}{}
			if _, seen := mountOrder[parts[0]]; !seen {
				mountOrder[parts[0]] = i
			}
		}
	}

	// Build a digest → friendly-name map from the on-disk manifest
	// cache so the output reads "qemu-guest-agent" instead of the bare
	// "sha256_<64-hex>" mount dirname. Cache lookup is best-effort —
	// modules whose manifest hasn't landed locally yet (or whose dir
	// name doesn't match the digest scheme) fall back to the dirname.
	digestToName := loadDigestNameMap(manifest.DefaultRoot)

	type modRow struct {
		dir      string // directory name under /run/powernode/modules
		display  string // friendly name when known, else dir
		attached bool
		rootfs   bool
	}
	var rows []modRow
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		rootfsExists := false
		if _, err := os.Stat(filepath.Join(moduleRoot, e.Name(), "rootfs")); err == nil {
			rootfsExists = true
		}
		_, ok := attachedSet[e.Name()]
		display := e.Name()
		// Mount dir is "sha256_<hex>"; manifest's digest field is
		// "sha256:<hex>". Normalize to look up the friendly name.
		digest := strings.Replace(e.Name(), "sha256_", "sha256:", 1)
		if name, found := digestToName[digest]; found && name != "" {
			display = name
		}
		rows = append(rows, modRow{
			dir: e.Name(), display: display, attached: ok, rootfs: rootfsExists,
		})
	}
	// Sort: attached modules in overlay mount order (top of stack first,
	// then descending priority); unattached modules after, alphabetical.
	// Mount-order is what the operator sees in `mount | grep overlay`
	// and matches the priority semantics declared in the template seed —
	// lower template-seed priority value = lower index in lowerdir =
	// higher position in this listing.
	sort.Slice(rows, func(i, j int) bool {
		oi, iAtt := mountOrder[rows[i].dir]
		oj, jAtt := mountOrder[rows[j].dir]
		switch {
		case iAtt && jAtt:
			return oi < oj
		case iAtt && !jAtt:
			return true
		case !iAtt && jAtt:
			return false
		default:
			return rows[i].display < rows[j].display
		}
	})

	if len(rows) == 0 {
		fmt.Printf("  (no modules in %s)\n", moduleRoot)
		return
	}
	fmt.Printf("  %-30s %-10s %s\n", "MODULE", "STATE", "ROOTFS")
	for _, r := range rows {
		state := "available"
		if r.attached {
			state = "attached"
		} else if !r.rootfs {
			state = "no-rootfs"
		}
		rootfsMark := "yes"
		if !r.rootfs {
			rootfsMark = "no"
		}
		fmt.Printf("  %-30s %-10s %s\n", r.display, state, rootfsMark)
	}
}

// loadDigestNameMap scans the on-disk manifest cache and returns
// digest → module-name. Manifests are at <root>/<module-id>/manifest.json
// per manifest.DefaultRoot. Best-effort: missing/unreadable manifests
// are silently skipped — the caller falls back to the dirname.
func loadDigestNameMap(root string) map[string]string {
	out := map[string]string{}
	entries, err := os.ReadDir(root)
	if err != nil {
		return out
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		m, err := manifest.LoadFromDisk(root, e.Name())
		if err != nil || m == nil {
			continue
		}
		if m.Digest != "" && m.Name != "" {
			out[m.Digest] = m.Name
		}
	}
	return out
}

// overlayLowerdirs scans /proc/mounts for an overlay mounted at /sysroot
// or /, parses the lowerdir option, and returns the path list.
func overlayLowerdirs() []string {
	data, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return nil
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		fsType, mp, opts := fields[2], fields[1], fields[3]
		if fsType != "overlay" {
			continue
		}
		if mp != "/" && mp != "/sysroot" {
			continue
		}
		for _, opt := range strings.Split(opts, ",") {
			if v, ok := strings.CutPrefix(opt, "lowerdir="); ok {
				return strings.Split(v, ":")
			}
		}
	}
	return nil
}

// printRelevantMounts prints the powernode-related mountpoints from
// /proc/mounts: the 9p share, the overlay union, and the persist volume.
// Filters out the noise of /sys, /proc, /dev, etc.
func printRelevantMounts() {
	data, err := os.ReadFile("/proc/mounts")
	if err != nil {
		fmt.Printf("  (cannot read /proc/mounts: %v)\n", err)
		return
	}
	type row struct{ src, dst, fs, opts string }
	var rows []row
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		src, dst, fs := f[0], f[1], f[2]
		// Surface mounts that matter to the agent: 9p shares, the overlay
		// union, the persist volume, anything under /run/powernode.
		switch {
		case fs == "9p":
		case fs == "overlay":
		case strings.HasPrefix(dst, "/run/powernode"):
		case strings.HasPrefix(dst, "/persist"):
		case dst == "/sysroot":
		default:
			continue
		}
		rows = append(rows, row{src: src, dst: dst, fs: fs, opts: f[3]})
	}
	if len(rows) == 0 {
		fmt.Println("  (no relevant mounts)")
		return
	}
	fmt.Printf("  %-12s %-30s %-10s %s\n", "FS", "MOUNTPOINT", "SOURCE", "OPTS")
	for _, r := range rows {
		opts := r.opts
		if len(opts) > 80 {
			opts = opts[:77] + "..."
		}
		fmt.Printf("  %-12s %-30s %-10s %s\n", r.fs, r.dst, r.src, opts)
	}
}

func execCmd() *cobra.Command {
	var (
		platformURL   string
		pkiDir        string
		timeout       time.Duration
		asUser        string
		allowUnsigned bool
		jsonOut       bool
		allowlistPath string
	)
	c := &cobra.Command{
		Use:   "exec <script-id> [args...]",
		Short: "Fetch + run a NodeScript with privilege drop (legacy ipn -e)",
		Args:  cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			res, runErr := agentcli.RunExec(cmd.Context(), agentcli.ExecOptions{
				ScriptID:      args[0],
				Args:          args[1:],
				PlatformURL:   platformURL,
				PKIDir:        pkiDir,
				Timeout:       timeout,
				AsUser:        asUser,
				AllowUnsigned: allowUnsigned,
				JSON:          jsonOut,
				AllowlistPath: allowlistPath,
			})
			return renderCLI(cmd, res, runErr, jsonOut)
		},
	}
	c.Flags().StringVar(&platformURL, "platform-url", "", "platform base URL (defaults to identity-discovered)")
	c.Flags().StringVar(&pkiDir, "pki-dir", "", "agent PKI directory")
	c.Flags().DurationVar(&timeout, "timeout", 5*time.Minute, "max script runtime")
	c.Flags().StringVar(&asUser, "as-user", "", "drop privileges to this user (overrides script policy)")
	c.Flags().BoolVar(&allowUnsigned, "allow-unsigned", false, "skip signature requirement (DEV ONLY)")
	c.Flags().StringVar(&allowlistPath, "allowlist", "/persist/var/lib/powernode/exec_allowlist.json",
		"per-instance privileged-exec allowlist (operator-managed)")
	c.Flags().BoolVar(&jsonOut, "json", false, "emit JSON output")
	return c
}

func syncCmd() *cobra.Command {
	var (
		platformURL string
		pkiDir      string
		dryRun      bool
		jsonOut     bool
	)
	c := &cobra.Command{
		Use:   "sync",
		Short: "One reconcile cycle: modules + authorized_keys (legacy ipn -S)",
		RunE: func(cmd *cobra.Command, args []string) error {
			res, runErr := agentcli.RunSync(cmd.Context(), agentcli.SyncOptions{
				PlatformURL: platformURL,
				PKIDir:      pkiDir,
				DryRun:      dryRun,
				JSON:        jsonOut,
			})
			return renderCLI(cmd, res, runErr, jsonOut)
		},
	}
	c.Flags().StringVar(&platformURL, "platform-url", "", "platform base URL (defaults to identity-discovered)")
	c.Flags().StringVar(&pkiDir, "pki-dir", "", "agent PKI directory (default: /persist/var/lib/powernode/pki)")
	c.Flags().BoolVar(&dryRun, "dry-run", false, "print planned actions without executing")
	c.Flags().BoolVar(&jsonOut, "json", false, "emit JSON output instead of human-readable lines")
	return c
}

func initCmd() *cobra.Command {
	var jsonOut bool
	c := &cobra.Command{
		Use:   "init <module-id> <action>",
		Short: "Run a module's init action; action is start|stop|restart|reload|status (legacy ipn -I)",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			res, runErr := agentcli.RunInit(cmd.Context(), agentcli.InitOptions{
				ModuleID: args[0],
				Action:   args[1],
				JSON:     jsonOut,
			})
			return renderCLI(cmd, res, runErr, jsonOut)
		},
	}
	c.Flags().BoolVar(&jsonOut, "json", false, "emit JSON output instead of human-readable lines")
	return c
}

func volumeSetupCmd() *cobra.Command {
	var (
		platformURL       string
		pkiDir            string
		policyName        string
		force             bool
		confirmDeviceWipe string
		dryRun            bool
		jsonOut           bool
	)
	c := &cobra.Command{
		Use:   "volume-setup <device>",
		Short: "Partition + format a disk per node policy (legacy ipn -X)",
		Long: `Default behavior is dry-run — prints the planned parted + mkfs sequence
without executing. To actually destroy data on the device, BOTH --force AND
--confirm-device-wipe=<device> must be set, with --confirm-device-wipe
matching <device> exactly. Refuses devices that are mounted or that look
like the system root disk.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			res, runErr := agentcli.RunVolumeSetup(cmd.Context(), agentcli.VolumeSetupOptions{
				Device:            args[0],
				PolicyName:        policyName,
				Force:             force,
				ConfirmDeviceWipe: confirmDeviceWipe,
				DryRun:            dryRun,
				JSON:              jsonOut,
				PlatformURL:       platformURL,
				PKIDir:            pkiDir,
			})
			return renderCLI(cmd, res, runErr, jsonOut)
		},
	}
	c.Flags().StringVar(&platformURL, "platform-url", "", "platform base URL (defaults to identity-discovered)")
	c.Flags().StringVar(&pkiDir, "pki-dir", "", "agent PKI directory")
	c.Flags().StringVar(&policyName, "policy", "default", "disk_policy profile name to apply")
	c.Flags().BoolVar(&force, "force", false, "actually execute the plan (default = dry-run)")
	c.Flags().StringVar(&confirmDeviceWipe, "confirm-device-wipe", "", "must match <device> exactly when --force is set")
	c.Flags().BoolVar(&dryRun, "dry-run", false, "alias for default behavior — print plan only")
	c.Flags().BoolVar(&jsonOut, "json", false, "emit JSON output")
	return c
}

func puppetCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "puppet",
		Short: "Puppet integration (apply manifests fetched from platform)",
	}

	var (
		platformURL          string
		pkiDir               string
		noop                 bool
		tags                 []string
		timeout              time.Duration
		allowChangesOver     int
		allowIdentityChanges bool
		jsonOut              bool
	)
	apply := &cobra.Command{
		Use:   "apply",
		Short: "Fetch + apply Puppet manifest with safety guards (legacy ipn -p)",
		Long: `Always runs --noop first to compute the change set. Refuses to apply if
changes exceed --allow-changes-over (default 50) OR if changes touch identity-
bearing files (/etc/sudoers, /etc/passwd, /etc/ssh) without --allow-identity-changes.
Maps puppet --detailed-exitcodes (0/2/4/6) to CLI exit codes (0/0/9/10).`,
		RunE: func(cmd *cobra.Command, args []string) error {
			res, runErr := agentcli.RunPuppetApply(cmd.Context(), agentcli.PuppetApplyOptions{
				Noop:                 noop,
				Tags:                 tags,
				Timeout:              timeout,
				AllowChangesOver:     allowChangesOver,
				AllowIdentityChanges: allowIdentityChanges,
				JSON:                 jsonOut,
				PlatformURL:          platformURL,
				PKIDir:               pkiDir,
			})
			return renderCLI(cmd, res, runErr, jsonOut)
		},
	}
	apply.Flags().StringVar(&platformURL, "platform-url", "", "platform base URL (defaults to identity-discovered)")
	apply.Flags().StringVar(&pkiDir, "pki-dir", "", "agent PKI directory")
	apply.Flags().BoolVar(&noop, "noop", false, "run --noop only; do not apply")
	apply.Flags().StringSliceVar(&tags, "tags", nil, "puppet --tags filter (comma-separated)")
	apply.Flags().DurationVar(&timeout, "timeout", 30*time.Minute, "max puppet apply runtime")
	apply.Flags().IntVar(&allowChangesOver, "allow-changes-over", 50, "refuse if --noop reports more than N changes")
	apply.Flags().BoolVar(&allowIdentityChanges, "allow-identity-changes", false, "permit changes to /etc/sudoers, /etc/passwd, /etc/ssh")
	apply.Flags().BoolVar(&jsonOut, "json", false, "emit JSON output")

	c.AddCommand(apply)
	return c
}

// abandonBootImageCmd clears a boot-slot upgrade that can never confirm.
//
// ConfirmBoot deliberately RETAINS Pending on the three branches where it cannot
// reach a verdict: efivars/LoaderInfo undeterminable, an empty booted git_sha
// with no contradicting slot signal, and running the pending slot while its image
// reports a different sha than was requested (what a wrong --target-git-sha
// produces). Refusing to guess is correct — the alternative deletes the only boot
// file of a slot that may be the running one.
//
// But Pending lives on /persist, and the in-flight guard in Apply refuses every
// subsequent upgrade while it is set. Within a boot the sha cannot change, so
// those branches never resolve; across boots they resolve only when systemd-boot
// exhausts the entry's boot counter, which needs three more reboots — on a
// long-uptime control plane, potentially never. Without this the only escape is
// hand-editing the state file.
//
// Abandoning touches the PENDING slot only: it clears the state and removes that
// slot's counter files. The ACTIVE slot — the rollback target, and on the
// no-verdict branches quite possibly what is actually running — is never touched.
func abandonBootImageCmd() *cobra.Command {
	var yes bool
	c := &cobra.Command{
		Use:   "abandon-boot-image",
		Short: "Clear a pending boot-slot upgrade that can never confirm (operator escape)",
		RunE: func(cmd *cobra.Command, args []string) error {
			st := bootslots.Load()
			if st.Pending == "" {
				fmt.Fprintln(cmd.OutOrStdout(), "no boot-image upgrade pending — nothing to abandon")
				return nil
			}
			out := cmd.OutOrStdout()
			fmt.Fprintf(out, "pending slot   : %s\n", st.Pending)
			fmt.Fprintf(out, "pending sha    : %s\n", st.PendingSHA)
			fmt.Fprintf(out, "active slot    : %s (will NOT be touched)\n", st.Active)
			if !yes {
				fmt.Fprintln(out, "\nDRY RUN — pass --yes to abandon. This clears the pending state and removes")
				fmt.Fprintln(out, "slot "+st.Pending+"'s counter files. If the node is CURRENTLY RUNNING the pending")
				fmt.Fprintln(out, "slot, that removes the image it booted from: reboot onto the active slot first.")
				return nil
			}
			// Order matters: clear the state BEFORE touching the ESP. If the ESP
			// removal fails we must not be left claiming an upgrade is still in
			// flight for files that are already gone.
			if err := bootslots.Update(func(s *bootslots.State) error {
				s.Pending = ""
				s.PendingSHA = ""
				return nil
			}); err != nil {
				return fmt.Errorf("clear pending state: %w", err)
			}
			if err := espwrite.CleanSlot(cmd.Context(), mount.ExecRunner{}, bootslots.EntryBase(st.Pending)); err != nil {
				// The state is already clear, so the upgrade IS abandoned and the
				// guard is unblocked; stale counter files are harmless (WriteUKISlot
				// clears the slot family before every write). Report, don't fail.
				fmt.Fprintf(cmd.ErrOrStderr(), "warning: pending state cleared but slot %s counter files remain: %v\n", st.Pending, err)
			}
			fmt.Fprintf(out, "\nabandoned: slot %s is no longer pending; upgrades are unblocked\n", st.Pending)
			return nil
		},
	}
	c.Flags().BoolVar(&yes, "yes", false, "actually abandon (default: dry-run)")
	return c
}

// lkgCmd groups read-only inspection of the frozen boot-LKG. Read-only on
// purpose: the mutating counterpart (repointing a module at a new blob) lives
// in the separate lkgretarget binary, whose safety contract — temp-file
// candidate, agent-owned validator, timestamped backup — should not be diluted
// by growing write paths here.
func lkgCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "lkg",
		Short: "Inspect the frozen boot last-known-good composition",
	}
	c.AddCommand(lkgValidateCmd())
	return c
}

// lkgValidateCmd answers "would this node boot from its LKG?" without a reboot
// and without shipping a tool to the node.
//
// This exists because the LKG is the file that decides whether a node boots at
// all, on nodes that typically cannot be re-provisioned, and until now the only
// way to check it was to copy lkgretarget over and run a dry-run — which is
// exactly what an operator does NOT want to be doing on a node they are already
// worried about. It runs the agent's own ValidateBootLKG, so a pass here means
// the same code the boot path uses accepted the file.
func lkgValidateCmd() *cobra.Command {
	var path, cacheDir string
	c := &cobra.Command{
		Use:   "validate",
		Short: "Check that the frozen boot-LKG is well-formed and every blob it needs is cached",
		RunE: func(cmd *cobra.Command, _ []string) error {
			out := cmd.OutOrStdout()
			lkg, err := runtime.LoadBootLKG(path)
			if err != nil {
				return fmt.Errorf("load %s: %w", path, err)
			}
			fmt.Fprintf(out, "path     : %s\n", path)
			fmt.Fprintf(out, "frozen   : %v\n", lkg.Frozen)
			fmt.Fprintf(out, "source   : %s\n", lkg.Source)
			fmt.Fprintf(out, "modules  : %d\n", len(lkg.Modules))

			cachePath := func(d string) string {
				return filepath.Join(cacheDir, strings.Replace(d, "sha256:", "sha256_", 1)+".erofs")
			}

			// Report EVERY missing blob, not just the first. ValidateBootLKG stops
			// at the first failure, which would make an operator fix one module,
			// re-run, and discover the next — the worst possible loop on a node
			// that is already in trouble.
			missing := 0
			for _, m := range lkg.Modules {
				p := cachePath(m.Digest)
				if _, statErr := os.Stat(p); statErr != nil {
					fmt.Fprintf(out, "  MISSING blob  %-30s %s\n", m.Name, m.Digest)
					missing++
				}
			}

			if err := runtime.ValidateBootLKG(lkg, cachePath); err != nil {
				fmt.Fprintf(out, "\nINVALID: %v\n", err)
				return fmt.Errorf("boot-LKG would be REJECTED by the boot path")
			}
			if missing > 0 {
				// Defensive: ValidateBootLKG is the authority, so this should be
				// unreachable. If it ever fires, the two disagree and that is worth
				// surfacing rather than silently reporting VALID.
				return fmt.Errorf("%d blob(s) missing but the validator passed — "+
					"validator and cache check disagree, do NOT trust this LKG", missing)
			}
			fmt.Fprintln(out, "\nVALID — the boot path would accept this composition,")
			fmt.Fprintln(out, "and every module blob it needs is already in the cache.")
			return nil
		},
	}
	c.Flags().StringVar(&path, "path", runtime.BootLKGPath, "frozen LKG path")
	c.Flags().StringVar(&cacheDir, "cache-dir", "/persist/cache/modules", "module erofs blob cache")
	return c
}

// retryPendingComposeCmd gives a staged-but-exhausted composition one more
// chance, without hand-editing /persist.
//
// TakePendingCompose burns an attempt BEFORE composing, so a set that panics
// the node cannot retry forever — correct, but it means a set that failed for a
// reason the operator has since FIXED (a blob that was missing and is now
// cached, a health-gate URL that was wrong) stays abandoned with no way back
// except deleting the file, which on a self-hosted control plane is the one
// thing that bricks it. Resetting the counter is the safe inverse.
func retryPendingComposeCmd() *cobra.Command {
	var yes bool
	c := &cobra.Command{
		Use:   "retry-pending-compose",
		Short: "Reset the attempt counter on a staged composition so the next boot tries it again",
		RunE: func(cmd *cobra.Command, _ []string) error {
			out := cmd.OutOrStdout()
			p, err := runtime.LoadPendingCompose(runtime.PendingComposePath)
			if err != nil {
				if os.IsNotExist(err) {
					fmt.Fprintln(out, "no staged composition — nothing to retry")
					return nil
				}
				return fmt.Errorf("load pending compose: %w", err)
			}
			fmt.Fprintf(out, "staged at : %s\n", p.StagedAt.Format(time.RFC3339))
			fmt.Fprintf(out, "modules   : %d\n", len(p.Set.Modules))
			fmt.Fprintf(out, "attempts  : %d of %d used\n", p.Attempts, runtime.PendingMaxTries)
			if p.Reason != "" {
				fmt.Fprintf(out, "reason    : %s\n", p.Reason)
			}
			if p.Attempts == 0 {
				fmt.Fprintln(out, "\nalready has its full attempt budget — nothing to reset")
				return nil
			}
			if !yes {
				fmt.Fprintln(out, "\nDRY RUN — pass --yes to reset the counter to 0.")
				fmt.Fprintln(out, "Only do this once the reason it failed is actually fixed: the counter is")
				fmt.Fprintln(out, "what stops a set that hangs or panics the node from retrying forever.")
				return nil
			}
			p.Attempts = 0
			if err := runtime.WritePendingCompose(runtime.PendingComposePath, p); err != nil {
				return fmt.Errorf("write pending compose: %w", err)
			}
			fmt.Fprintln(out, "\nattempt counter reset — the next boot will try this composition again")
			return nil
		},
	}
	c.Flags().BoolVar(&yes, "yes", false, "actually reset the counter (default: dry run)")
	return c
}
