// Package lifecycle materializes systemd unit files from the platform's
// `system_module_services` rows (surfaced to the agent as
// manifest.Service entries) and wires them into module attach/detach.
//
// Why systemd-native: each service inherits all of systemd's lifecycle
// guarantees — Restart= for restart_policy, Environment= for env,
// User= for user, journalctl for stdout/stderr — without the agent
// reimplementing a process supervisor.
//
// Topological order: outgoing dependencies on a service mean "start
// these first." We use Kahn's algorithm to produce a deterministic
// start order, with a stable secondary key (name asc) so two
// independent services always land in the same order across
// reconcile passes.
//
// Unit naming: powernode-<module-id>-<service-name>.service. The
// per-module prefix scopes them so two modules can ship services
// with the same human name without colliding.
//
// Plan reference: P8.1 (ipn-agent init_start/init_stop per
// system_module_services rows).
package lifecycle

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/systemd"
)

// DefaultUnitDir is where systemd looks for operator-installed units.
// Override via POWERNODE_LIFECYCLE_UNIT_DIR for dev/test isolation.
const DefaultUnitDir = "/etc/systemd/system"

// UnitDir returns the unit directory, honoring the env override.
func UnitDir() string {
	if v := os.Getenv("POWERNODE_LIFECYCLE_UNIT_DIR"); v != "" {
		return v
	}
	return DefaultUnitDir
}

// UnitName composes the canonical systemd unit name for a service on
// a given module. Format: powernode-<module-id>-<svc-name>.service.
// Module-id prefix scopes the unit so two modules with same-named
// services don't collide.
func UnitName(moduleID, svcName string) string {
	return fmt.Sprintf("powernode-%s-%s.service", moduleID, svcName)
}

// UnitPath joins the configured unit dir with UnitName.
func UnitPath(moduleID, svcName string) string {
	return filepath.Join(UnitDir(), UnitName(moduleID, svcName))
}

// AttachServices writes one systemd unit file per service, runs
// daemon-reload, then starts each service in topological order over
// declared dependencies. Idempotent: re-running on an already-attached
// module updates unit content + restarts only services whose unit
// file content actually changed.
//
// Returns the ordered list of (unit-name, started?) tuples so the
// caller can log + heartbeat per-service health.
type AttachResult struct {
	Unit    string
	Started bool
	Skipped bool  // already running with identical unit content
	StepErr error // non-nil for the step that failed; preceding steps still ran
}

// AttachServices renders each unit in the cloud_init chroot mode
// (RootDirectory=/sysroot) into the live unit dir, then daemon-reloads
// and starts. Thin wrapper over AttachServicesMode preserved for the
// operator `init` CLI (cloud_init hosts) and existing callers/tests.
//
// The reconcile loop must NOT use this directly — it runs in BOTH boot
// models and has to pick the mode by boot context (see
// AttachServicesMode + PivotAwareRootMode). A chroot-rendered unit on a
// pivoted host stamps RootDirectory=/sysroot, which no longer exists
// after switch_root, so the service never starts.
func AttachServices(ctx context.Context, runner mount.Runner, moduleID string, services []manifest.Service) ([]AttachResult, error) {
	return AttachServicesMode(ctx, runner, moduleID, services, RootModeChroot)
}

// AttachServicesMode is AttachServices with an explicit root mode. Both
// modes write units into the LIVE unit dir (UnitDir()), daemon-reload,
// and start immediately — the difference is only how each unit resolves
// its filesystem root:
//   - RootModeChroot: cloud_init model, RootDirectory=/sysroot (the guest
//     OS is /, modules chroot into the overlay-composed union at /sysroot).
//   - RootModeNative: direct_kernel/pivot_root model, no RootDirectory —
//     the module union itself became / via switch_root, so ExecStart/proc/
//     passwd resolve natively. This is the correct mode for the post-pivot
//     reconcile loop; RootModeChroot there points every unit at a /sysroot
//     that no longer exists and the service can't start.
func AttachServicesMode(ctx context.Context, runner mount.Runner, moduleID string, services []manifest.Service, mode RootMode) ([]AttachResult, error) {
	if runner == nil {
		return nil, errors.New("lifecycle.AttachServices: nil runner")
	}
	if len(services) == 0 {
		return nil, nil
	}

	ordered, err := topoSort(services)
	if err != nil {
		return nil, fmt.Errorf("topoSort: %w", err)
	}

	dir := UnitDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", dir, err)
	}

	// Inverted edges, computed once over the WHOLE service set: a unit's
	// recovery directive names its dependents, which no single Service
	// carries. See recoveryDependents / writeDependencyDirectives.
	dependents := recoveryDependents(services)

	results := make([]AttachResult, 0, len(ordered))
	anyWritten := false
	for _, svc := range ordered {
		unitName := UnitName(moduleID, svc.Name)
		path := filepath.Join(dir, unitName)
		body := RenderUnitModeGraph(svc, moduleID, mode, dependents[svc.Name])

		written, err := writeIfChanged(path, body)
		if err != nil {
			results = append(results, AttachResult{Unit: unitName, StepErr: fmt.Errorf("write %s: %w", path, err)})
			return results, err
		}
		anyWritten = anyWritten || written
		results = append(results, AttachResult{Unit: unitName, Skipped: !written})
	}

	if anyWritten {
		if err := runner.Run(ctx, "systemctl", "daemon-reload"); err != nil {
			return results, fmt.Errorf("daemon-reload: %w", err)
		}
	}

	// Start services in topological order. enable-now would persist
	// across reboots, but we want the agent to be the source of truth
	// after reboot — so we use start (not enable) so a removed module
	// doesn't ghost-start on the next boot.
	for i, svc := range ordered {
		unitName := UnitName(moduleID, svc.Name)
		if err := systemd.Action(ctx, runner, unitName, systemd.Start); err != nil {
			results[i].StepErr = err
			return results, fmt.Errorf("start %s: %w", unitName, err)
		}
		results[i].Started = !results[i].Skipped // unchanged units still get started so a manual stop is corrected
		if results[i].Skipped {
			// Idempotent: systemctl start on a running unit is a no-op,
			// so we mark started=true to reflect the actual end-state.
			results[i].Started = true
		}
	}

	return results, nil
}

// AttachServicesNative renders + offline-enables a module's units inside the
// composed union at `sysroot`, for the direct_kernel/pivot_root boot model.
//
// Difference from AttachServices (the cloud_init chroot path):
//   - units render in RootModeNative (no RootDirectory — the union becomes /
//     after switch_root, so ExecStart/proc/passwd resolve natively);
//   - units are written under <sysroot>/etc/systemd/system (the union's own
//     unit tree, which is /etc/systemd/system once it becomes /);
//   - units are ENABLED offline via `systemctl --root=<sysroot> enable` (writes
//     the WantedBy symlinks without a running systemd) rather than started —
//     systemd-in-the-union starts them on boot after the pivot.
//
// No daemon-reload (no live systemd owns this root yet). Topological order
// still drives the unit's After=/Requires= which systemd honors at boot.
func AttachServicesNative(ctx context.Context, runner mount.Runner, moduleID string, services []manifest.Service, sysroot string) ([]AttachResult, error) {
	if runner == nil {
		return nil, errors.New("lifecycle.AttachServicesNative: nil runner")
	}
	if sysroot == "" {
		return nil, errors.New("lifecycle.AttachServicesNative: empty sysroot")
	}
	if len(services) == 0 {
		return nil, nil
	}

	ordered, err := topoSort(services)
	if err != nil {
		return nil, fmt.Errorf("topoSort: %w", err)
	}

	dir := filepath.Join(sysroot, "etc", "systemd", "system")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", dir, err)
	}

	dependents := recoveryDependents(services)

	results := make([]AttachResult, 0, len(ordered))
	for _, svc := range ordered {
		unitName := UnitName(moduleID, svc.Name)
		path := filepath.Join(dir, unitName)
		body := RenderUnitModeGraph(svc, moduleID, RootModeNative, dependents[svc.Name])
		written, err := writeIfChanged(path, body)
		if err != nil {
			results = append(results, AttachResult{Unit: unitName, StepErr: fmt.Errorf("write %s: %w", path, err)})
			return results, err
		}
		results = append(results, AttachResult{Unit: unitName, Skipped: !written})
	}

	// Offline-enable each unit into the union so systemd-in-the-union starts it
	// on boot (post-switch_root). `systemctl --root` operates on the on-disk unit
	// tree without contacting a running manager.
	for i, svc := range ordered {
		unitName := UnitName(moduleID, svc.Name)
		if err := runner.Run(ctx, "systemctl", "--root="+sysroot, "enable", unitName); err != nil {
			results[i].StepErr = err
			return results, fmt.Errorf("enable %s (--root=%s): %w", unitName, sysroot, err)
		}
		results[i].Started = true // enabled → systemd-in-union will start it at boot
	}

	return results, nil
}

// DetachServices stops each service in REVERSE topological order
// (dependents come down before their dependencies), removes the unit
// files, and reloads systemd. Best-effort: a single stop failure
// surfaces but doesn't block the rest from coming down.
func DetachServices(ctx context.Context, runner mount.Runner, moduleID string, services []manifest.Service) ([]AttachResult, error) {
	if runner == nil {
		return nil, errors.New("lifecycle.DetachServices: nil runner")
	}
	if len(services) == 0 {
		return nil, nil
	}

	ordered, err := topoSort(services)
	if err != nil {
		// On detach we don't strictly need a valid topo (we're tearing
		// down); fall through to the unsorted list. But log it.
		ordered = services
	}

	// Reverse for tear-down.
	reversed := make([]manifest.Service, len(ordered))
	for i := range ordered {
		reversed[i] = ordered[len(ordered)-1-i]
	}

	results := make([]AttachResult, 0, len(reversed))
	var firstErr error
	for _, svc := range reversed {
		unitName := UnitName(moduleID, svc.Name)
		path := filepath.Join(UnitDir(), unitName)
		stopErr := systemd.Action(ctx, runner, unitName, systemd.Stop)
		if stopErr != nil && firstErr == nil {
			firstErr = stopErr
		}
		// Remove the unit file regardless of stop outcome — a stop
		// failure usually means the unit doesn't exist (already
		// removed) or systemd hasn't loaded it. Either way, the file
		// is what we own; remove it.
		_ = os.Remove(path)
		results = append(results, AttachResult{Unit: unitName, Started: false, StepErr: stopErr})
	}

	// daemon-reload picks up the file removals so the unit definitions
	// disappear from `systemctl list-units` after detach.
	if err := runner.Run(ctx, "systemctl", "daemon-reload"); err != nil {
		if firstErr == nil {
			firstErr = fmt.Errorf("daemon-reload after detach: %w", err)
		}
	}

	return results, firstErr
}

// RootMode selects how a rendered unit resolves its filesystem root.
type RootMode int

const (
	// RootModeChroot renders units with RootDirectory=/sysroot (+ MountAPIVFS +
	// BindReadOnlyPaths for the live-root identity files) — the cloud_init model
	// where the guest OS is / and each module unit is chrooted into the
	// overlay-composed /sysroot.
	RootModeChroot RootMode = iota
	// RootModeNative omits RootDirectory entirely — the direct_kernel/pivot_root
	// model where the module union itself becomes / via switch_root, so ExecStart
	// paths, /proc, and /etc/passwd resolve natively in the union.
	RootModeNative
)

// rootProbePath is the mount whose filesystem type signals whether the
// module union has become the running root. Package var so tests can point
// it at a known path. Defaults to "/", the running process's root — which
// post-switch_root IS the composed overlay union.
var rootProbePath = "/"

// overlayfsMagic is the statfs f_type for overlayfs (OVERLAYFS_SUPER_MAGIC,
// linux/magic.h). The composed module union is an overlayfs; the initramfs
// root is rootfs/ramfs and a cloud_init guest root is ext4/xfs — none of
// which report this magic.
const overlayfsMagic = 0x794c7630

// rootFSType returns the statfs f_type of path. Package var so tests can
// inject a boot context without needing a real overlay mount.
var rootFSType = func(path string) (int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, err
	}
	return int64(st.Type), nil
}

// PivotAwareRootMode picks the unit render mode for the CURRENT root by
// asking whether switch_root has actually happened — i.e. whether "/" is
// now the composed overlay union:
//   - RootModeNative when / is the overlay union (direct_kernel/pivot_root:
//     the union became / via switch_root, so ExecStart/proc/passwd resolve
//     natively);
//   - RootModeChroot otherwise — the pre-pivot initramfs (where / is
//     rootfs/ramfs and the union is composed at /sysroot) and the cloud_init
//     model (guest OS is /, modules chroot into /sysroot).
//
// An earlier heuristic keyed on whether /persist read as a distinct mount,
// but persist.mount stages /persist as a distinct tmpfs for the WHOLE
// pivot_root lifecycle (pre-pivot initramfs AND post-pivot union), so it
// could not tell the initramfs reconcile from the pivoted union and wrongly
// returned native pre-pivot. Probing /'s filesystem type directly encodes
// "is the module union my root" and is timing-independent.
func PivotAwareRootMode() RootMode {
	if t, err := rootFSType(rootProbePath); err == nil && t == overlayfsMagic {
		return RootModeNative
	}
	return RootModeChroot
}

// RenderUnit renders a unit in the default chroot mode (cloud_init model).
// Equivalent to RenderUnitMode(svc, moduleID, RootModeChroot).
func RenderUnit(svc manifest.Service, moduleID string) string {
	return RenderUnitMode(svc, moduleID, RootModeChroot)
}

// RenderUnitMode produces the [Unit]/[Service]/[Install] systemd unit body
// for a single Service in the given root mode. Public so tests can assert
// the content shape without touching the filesystem.
func RenderUnitMode(svc manifest.Service, moduleID string, mode RootMode) string {
	return RenderUnitModeGraph(svc, moduleID, mode, nil)
}

// RenderUnitModeGraph is RenderUnitMode with the service's INVERTED edges
// supplied: `dependents` names the sibling services (bare names, not unit
// names) that declared a necessity edge on svc, as computed by
// recoveryDependents over the module's whole service set.
//
// It exists because the outage this fixes is not expressible from one
// service's own fields. See writeDependencyDirectives for what the
// directive does and what it costs. Callers that render a single service
// out of graph context (RenderUnit, RenderUnitMode) pass nil and get the
// pre-existing output byte-for-byte.
func RenderUnitModeGraph(svc manifest.Service, moduleID string, mode RootMode, dependents []string) string {
	if svc.UnitBody != "" {
		return renderUnitBodyMode(svc, moduleID, mode, dependents)
	}

	var b strings.Builder
	b.WriteString("# Auto-generated by powernode-agent for module ")
	b.WriteString(moduleID)
	b.WriteString(" / service ")
	b.WriteString(svc.Name)
	b.WriteString(".\n")
	b.WriteString("# DO NOT EDIT BY HAND — overwritten on every reconcile.\n")

	b.WriteString("\n[Unit]\n")
	b.WriteString("Description=Powernode service ")
	b.WriteString(svc.Name)
	b.WriteString(" (module ")
	b.WriteString(moduleID)
	b.WriteString(")\n")
	// len(dependents) > 0 with NO outgoing edges is the exact shape of the
	// unit that stranded the fleet: dev-cell's bootstrap depends on nothing
	// and is depended on by three services. Gating this block on outgoing
	// edges alone would emit no directive on precisely those units.
	if edges := svc.ResolvedDependencyEdges(); len(edges) > 0 || len(dependents) > 0 {
		writeDependencyDirectives(&b, moduleID, edges, dependents)
	}

	b.WriteString("\n[Service]\n")
	b.WriteString("Type=simple\n")
	// Filesystem-root handling depends on the boot model:
	//
	// chroot (cloud_init): RootDirectory=/sysroot makes systemd resolve ExecStart
	// + working dir + reads inside the overlay-composed rootfs rather than the
	// live / (module start_commands like /usr/bin/redis-server live in the module
	// erofs, not the cloud image; without it systemd execs the live root's
	// nonexistent binary and fails 203/EXEC). MountAPIVFS=yes is mandatory with
	// RootDirectory (else 226/NAMESPACE on the first /proc or /dev access).
	// BindReadOnlyPaths bridges the live-root identity files (etcidentity renders
	// postgres@70110/redis@70140/... there) into the chroot so User= + chown
	// resolve the platform UIDs; the UID lookup itself uses the live /etc/passwd
	// (systemd resolves it before chrooting).
	//
	// native (direct_kernel/pivot): the module union IS / after switch_root, so
	// ExecStart, /proc /sys /dev, and the union's own etcidentity-rendered
	// /etc/passwd all resolve natively — none of these directives apply.
	if mode == RootModeChroot {
		b.WriteString("RootDirectory=/sysroot\n")
		b.WriteString("MountAPIVFS=yes\n")
		b.WriteString("BindReadOnlyPaths=/etc/passwd /etc/group /etc/shadow /etc/gshadow\n")
	}
	if svc.User != "" {
		fmt.Fprintf(&b, "User=%s\n", svc.User)
	}
	if svc.WorkingDirectory != "" {
		fmt.Fprintf(&b, "WorkingDirectory=%s\n", svc.WorkingDirectory)
	}
	// StateDirectory= makes systemd itself create the /var/lib/<x> dir
	// (mode 0755) and chown it to User= at service start, resolving the
	// platform-rendered passwd UID at *runtime* — never a numerically
	// baked-in owner. This matters on pivot-booted fleet nodes: the
	// composed erofs module union ships with --all-root (mkfs.erofs),
	// which drops /var entirely, so a plain WorkingDirectory= under
	// /var/lib is never created and the non-root User= hits EACCES/
	// 200-CHDIR. Only applies when both User= is set (nothing to chown
	// to otherwise) and WorkingDirectory is actually under /var/lib —
	// e.g. /etc/traefik or other non-state working dirs are left alone.
	if svc.User != "" {
		if stateDir, ok := varLibStateDirectory(svc.WorkingDirectory); ok {
			fmt.Fprintf(&b, "StateDirectory=%s\n", stateDir)
		}
	}
	for _, k := range sortedKeys(svc.Env) {
		// systemd accepts Environment= with shell-escaping; we keep it
		// simple — values pre-escaped by the operator land verbatim.
		fmt.Fprintf(&b, "Environment=%s=%s\n", k, svc.Env[k])
	}
	b.WriteString("ExecStart=")
	b.WriteString(svc.StartCommand)
	b.WriteString("\n")
	if svc.StopCommand != "" {
		b.WriteString("ExecStop=")
		b.WriteString(svc.StopCommand)
		b.WriteString("\n")
	}
	b.WriteString("Restart=")
	b.WriteString(restartDirective(svc.RestartPolicy))
	b.WriteString("\n")
	b.WriteString("RestartSec=5s\n")

	b.WriteString("\n[Install]\n")
	b.WriteString("WantedBy=multi-user.target\n")
	return b.String()
}

// writeDependencyDirectives writes the ordering and necessity lines for a
// service's dependency edges into an already-opened [Unit] section. Shared by
// the generated-unit path and renderUnitBodyMode's appended [Unit] section so
// both name dependent units identically. Each directive's units are sorted for
// stable output (same input → same file → writeIfChanged correctly skips a
// no-op re-attach).
//
// The KIND of each edge decides which necessity directive it lands on.
// System::ModuleServiceDependency (server/app/models/system/
// module_service_dependency.rb:8-12) is the specification:
//
//	start_before     target must be running before source starts
//	requires_health  target must pass its health check before source starts
//	softdep          target preferred-running but NOT required (best-effort)
//
// Rendering:
//
//   - After= carries EVERY edge regardless of kind. All three kinds are
//     ordering constraints; they differ only in how badly the source needs
//     the target to have succeeded.
//   - Requires= carries start_before and requires_health. These two coincide
//     because systemd has no notion of the agent's own health checks, so
//     "healthy first" is not expressible as a directive distinct from
//     "started first"; the strict form is the conservative reading.
//   - Wants= carries softdep, and only softdep. "Preferred but not required"
//     is exactly what Wants= means, and rendering it as Requires= made a
//     dependency the manifest declared as optional able to strand its
//     dependent — the edge reads soft and behaved hard.
//   - An UNRECOGNISED kind falls to Requires=, never Wants= and never
//     dropped. A server teaching the fleet a kind this agent predates must
//     not silently downgrade a necessity guarantee.
//
// RECOVERY — the inverted edge, and what it costs (IMP-4e0f282bb9f0).
//
// Requires= means "cancel my start job if the dependency fails"; it does
// NOT mean "start me when the dependency later succeeds". A dependency
// that fails and then self-heals leaves its hard dependents stopped
// forever, because systemd never re-runs the cancelled job. That is what
// stranded dev-cell's mcp-proxy behind a transiently-failing bootstrap on
// 2026-08-31: bootstrap's start job failed on six HTTP 502s, mcp-proxy's
// job was cancelled, bootstrap retried under Restart=on-failure and
// succeeded 107 seconds later, and mcp-proxy stayed dead until a human ran
// `systemctl start`.
//
// Closing that needs a directive on the DEPENDENCY unit naming its
// dependents, which is why `dependents` is threaded in from
// recoveryDependents rather than read off svc: a Service carries only its
// OUTGOING edges. It renders as Wants= — merged into the same sorted line
// as any outgoing softdep, since systemd keeps one Wants= list per unit.
//
// WHY Wants= AND NOT Upholds=. Upholds= is the directive that advertises
// itself for this ("as long as this unit is up, keep those started"), and
// a hand-written Upholds= drop-in is what recovered dev-cell by hand. It
// is nevertheless the wrong directive to GENERATE, because it is a
// CONTINUOUS want and this function renders every edge on every fleet
// node. Measured on systemd 255 (255.4-1ubuntu8, the fleet's own version),
// dependency active throughout:
//
//	property                                 Wants=        Upholds=
//	recovers a stranded dependent            yes           yes
//	`systemctl stop <dependent>` is undone   next start    <2s, always
//	                                         job of the
//	                                         dependency
//	skip-logs/30s, condition-gated dependent 1             49
//
// Read the middle row carefully — it is a DIFFERENCE OF DEGREE, not of
// kind, and the earlier draft of this comment overstated it as "the stop
// sticks". Under Upholds= a stop is reverted within two seconds,
// unconditionally. Under Wants= the stop holds only while the dependency
// issues no new start job — and every dependency unit in the shipped
// manifests carries Restart=on-failure, so one crash-restart of the
// dependency undoes an operator's stop of the dependent. What Wants= buys
// is a bounded window, not immunity. (For scale: AttachServicesMode
// already runs `systemctl start` over every unit on every reconcile —
// see the loop below — so an operator stop never durably survived anyway.
// This narrows the window from "next reconcile" to "next dependency
// start job".)
//
// PULL-UP, AND IT IS TRANSITIVE. A start job for a dependency now also
// starts its dependents, and each dependent drags in its OWN Requires=
// closure. On dev-cell that turns `systemctl restart <mcp-proxy>` from a
// one-unit operation into a five-unit one: it pulls up `executor` (which
// burns API credits) and re-runs the `credential` oneshot (a live
// credential fetch). The agent's own `restart` task issues exactly that
// command. This is the main operational cost of the change and it is
// accepted deliberately; a targeted restart of a DEPENDENT (the common
// case) is unaffected.
//
// `systemctl mask` is not an escape hatch for either directive, by the
// way — the agent writes a REAL file at /etc/systemd/system/<unit>, so
// mask refuses ("File ... already exists"). Stopping a dependent for
// maintenance means stopping it together with its dependency.
//
// The bottom row is worse, and it is what actually rules Upholds= out
// here. An uphold-triggered start of a unit whose Condition*= is unmet is
// not a FAILED start, so it does not durably trip StartLimitBurst; systemd
// re-tries it about twice a second, forever. Seven of the nine dependency
// edges shipped in modules/*/manifest.yaml have a condition-gated
// dependent, and dev-cell's `provision` is gated on
// ConditionPathExists=!/persist/dev-cell/state/provisioned — permanently
// false on every cell that IS provisioned, i.e. the steady state of the
// whole fleet. Upholds= would put a permanent journal hot-loop on every
// dev-cell.
//
// Wants= gives up one guarantee to avoid both costs: it is pulled in by
// the dependency's START JOB, not held continuously, so it will not
// resurrect a dependent that died while the dependency stayed up. That is
// the right trade. The outage class is "the dependency failed, so the
// dependent was cancelled" — and a dependency recovering from failure
// always does so via a start job, which re-expands Wants=. A dependent
// that instead exhausted its OWN StartLimitBurst is a unit systemd was
// deliberately told to give up on (dev-cell sets
// StartLimitIntervalSec=1800/StartLimitBurst=5 for exactly that, see
// modules/dev-cell/manifest.yaml), and reviving it would defeat the brake.
//
// The inverse is emitted for exactly the kinds that render Requires=;
// softdep gets none. See recoveryDependents for why that mirror is the
// whole rule.
func writeDependencyDirectives(b *strings.Builder, moduleID string, edges []manifest.DependencyEdge, dependents []string) {
	var all, required, wanted []string
	for _, e := range edges {
		unit := UnitName(moduleID, e.Service)
		all = append(all, unit)
		if e.Kind == manifest.DependencyKindSoftdep {
			wanted = append(wanted, unit)
			continue
		}
		// start_before, requires_health, and anything unrecognised.
		required = append(required, unit)
	}
	// The INVERTED edges. Same directive as softdep, deliberately: both mean
	// "start this too, best-effort" and systemd merges them into one list, so
	// they are rendered as one sorted Wants= rather than two lines.
	seen := make(map[string]bool, len(wanted))
	for _, u := range wanted {
		seen[u] = true
	}
	for _, name := range dependents {
		unit := UnitName(moduleID, name)
		if seen[unit] {
			continue
		}
		seen[unit] = true
		wanted = append(wanted, unit)
	}
	writeUnitList(b, "After=", all)
	writeUnitList(b, "Requires=", required)
	writeUnitList(b, "Wants=", wanted)
}

// recoveryDependents inverts a module's dependency graph: it maps each
// service name to the sibling services that declared a NECESSITY edge on
// it — precisely the set writeDependencyDirectives renders as Requires=.
// The result feeds RenderUnitModeGraph's `dependents` argument.
//
// Mirroring Requires= is the whole rule, and it is the rule because
// Requires= is what creates the strand: a cancelled start job is only ever
// left behind for an edge strong enough to cancel it. softdep never
// cancels anything, so it needs no inverse — and giving it one would be
// self-contradictory, dragging up a service the manifest called optional.
//
// Two degeneracies are dropped rather than rendered:
//   - a SELF-EDGE, which would emit a unit that names itself;
//   - an edge naming a service absent from this module's set, which has no
//     unit to carry the directive (topoSort tolerates the same case).
func recoveryDependents(services []manifest.Service) map[string][]string {
	if len(services) == 0 {
		return nil
	}
	present := make(map[string]bool, len(services))
	for _, s := range services {
		present[s.Name] = true
	}
	out := make(map[string][]string, len(services))
	for _, s := range services {
		seen := make(map[string]bool)
		for _, e := range s.ResolvedDependencyEdges() {
			if e.Kind == manifest.DependencyKindSoftdep {
				continue
			}
			if e.Service == s.Name || !present[e.Service] || seen[e.Service] {
				continue
			}
			seen[e.Service] = true
			out[e.Service] = append(out[e.Service], s.Name)
		}
	}
	for name := range out {
		sort.Strings(out[name])
	}
	return out
}

// writeUnitList writes "<directive><space-joined sorted units>\n", or
// nothing at all when the list is empty. Omitting the line is what "this
// service has no dependencies of that strength" means.
//
// Do NOT reach for an empty assignment ("Requires=") to clear a list: for
// the unit-dependency directives it is simply IGNORED, not a reset.
// Measured on systemd 255.4, a unit declaring Wants=/Requires=/After= and
// then the same directive empty keeps every entry:
//
//	Wants=a.service          then Wants=    -> Wants=a.service
//	Requires=a.service       then Requires= -> Requires=a.service ...
//
// (An earlier version of this comment asserted the opposite — that the
// empty form was a documented reset. It is not; the reset semantic
// belongs to directives like ConditionPathExists= and Environment=.
// Correcting it here because acting on the wrong version in this file
// strands services fleet-wide.) `systemd-analyze verify` reports nothing
// either way, so a stray empty line would be silently inert rather than
// caught.
func writeUnitList(b *strings.Builder, directive string, units []string) {
	if len(units) == 0 {
		return
	}
	sort.Strings(units)
	b.WriteString(directive)
	b.WriteString(strings.Join(units, " "))
	b.WriteString("\n")
}

// renderUnitBodyMode passes svc.UnitBody through verbatim (option A2 —
// dev-cell/claude-tmux's hand-tuned Type=oneshot/RemainAfterExit/
// RestartSec/StartLimit*/ExecStartPre semantics the structured Service
// fields above can't express), then appends:
//
//   - a generated [Unit] section carrying After=/Requires= for the
//     service's Dependencies, in the exact shape the generated-unit
//     path emits (same UnitName resolution, so sibling ordering
//     declared via `dependencies:` works identically whether or not
//     the service uses unit_body).
//   - under RootModeChroot only, an appended [Service] section with
//     the same chroot directives the generated path emits, so a
//     unit_body service's ExecStart (inside the body) still resolves
//     against /sysroot.
//
// systemd merges repeated [Unit]/[Service] sections in a unit file, so
// verbatim-body + appended-blocks is valid. No [Install] section is
// appended — the body carries its own WantedBy=, and appending a
// second [Install] section would be redundant at best.
func renderUnitBodyMode(svc manifest.Service, moduleID string, mode RootMode, dependents []string) string {
	var b strings.Builder
	b.WriteString("# Managed by powernode-agent — DO NOT EDIT.\n")
	b.WriteString(svc.UnitBody)
	if !strings.HasSuffix(svc.UnitBody, "\n") {
		b.WriteString("\n")
	}

	if edges := svc.ResolvedDependencyEdges(); len(edges) > 0 || len(dependents) > 0 {
		b.WriteString("\n[Unit]\n")
		writeDependencyDirectives(&b, moduleID, edges, dependents)
	}

	if mode == RootModeChroot {
		b.WriteString("\n[Service]\n")
		b.WriteString("RootDirectory=/sysroot\n")
		b.WriteString("MountAPIVFS=yes\n")
		b.WriteString("BindReadOnlyPaths=/etc/passwd /etc/group /etc/shadow /etc/gshadow\n")
	}

	return b.String()
}

// varLibStateDirectory reports whether workingDir is rooted under
// /var/lib/ and, if so, returns the path systemd's StateDirectory=
// directive should carry to reproduce it — e.g. /var/lib/vector ->
// "vector" (systemd then creates /var/lib/vector). Returns ok=false
// for anything outside /var/lib (e.g. /etc/traefik) or for /var/lib
// itself (no meaningful subdirectory to state-manage).
func varLibStateDirectory(workingDir string) (string, bool) {
	const prefix = "/var/lib/"
	if !strings.HasPrefix(workingDir, prefix) {
		return "", false
	}
	suffix := strings.TrimSuffix(strings.TrimPrefix(workingDir, prefix), "/")
	if suffix == "" {
		return "", false
	}
	return suffix, true
}

// restartDirective maps the plan's policy enum to systemd's directive.
//   - "always"     → Restart=always  (default in cluster-member service)
//   - "on-failure" → Restart=on-failure (default for cleanup-style services)
//   - "never"      → Restart=no
//   - empty/unknown → "on-failure" (safest default)
func restartDirective(policy string) string {
	switch strings.ToLower(strings.TrimSpace(policy)) {
	case "always":
		return "always"
	case "never":
		return "no"
	case "on-failure", "":
		return "on-failure"
	default:
		return "on-failure"
	}
}

// topoSort returns services in start order: a service appears after
// all its declared dependencies. Stable on ties (sort by name).
// Returns an error if a cycle exists.
func topoSort(services []manifest.Service) ([]manifest.Service, error) {
	if len(services) == 0 {
		return nil, nil
	}
	byName := make(map[string]manifest.Service, len(services))
	for _, s := range services {
		byName[s.Name] = s
	}

	inDegree := make(map[string]int, len(services))
	for _, s := range services {
		if _, ok := inDegree[s.Name]; !ok {
			inDegree[s.Name] = 0
		}
		for _, dep := range s.Dependencies {
			if _, present := byName[dep]; !present {
				// Dependency on a service that doesn't exist in this
				// module's service set — treat as unmet but don't fail
				// the topo (the agent operator can see this in logs).
				continue
			}
			inDegree[s.Name]++
		}
	}

	// Kahn's algorithm with sorted candidate selection for stability.
	var ready []string
	for name, deg := range inDegree {
		if deg == 0 {
			ready = append(ready, name)
		}
	}
	sort.Strings(ready)

	var ordered []manifest.Service
	for len(ready) > 0 {
		// Pop the lexicographically smallest ready name.
		current := ready[0]
		ready = ready[1:]
		ordered = append(ordered, byName[current])

		// Decrement neighbors. The graph is "depended-by", so we walk
		// every service whose dependency list includes `current`.
		for _, s := range services {
			for _, d := range s.Dependencies {
				if d == current {
					inDegree[s.Name]--
					if inDegree[s.Name] == 0 {
						ready = append(ready, s.Name)
					}
				}
			}
		}
		sort.Strings(ready)
	}

	if len(ordered) != len(services) {
		// Cycle: at least one service has unfulfilled deps after
		// processing. Report what's left for operator visibility.
		var stuck []string
		for _, s := range services {
			found := false
			for _, o := range ordered {
				if o.Name == s.Name {
					found = true
					break
				}
			}
			if !found {
				stuck = append(stuck, s.Name)
			}
		}
		sort.Strings(stuck)
		return nil, fmt.Errorf("cycle in service dependencies; stuck: %v", stuck)
	}
	return ordered, nil
}

// writeIfChanged writes content to path only if the destination either
// doesn't exist or has different content. Returns true if a write
// happened. Idempotent: a no-change attach skips daemon-reload + the
// restart cycle, so a healthy module's reconcile tick is cheap.
func writeIfChanged(path, content string) (bool, error) {
	existing, err := os.ReadFile(path)
	if err == nil && string(existing) == content {
		return false, nil
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		return false, err
	}
	return true, nil
}

func sortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
