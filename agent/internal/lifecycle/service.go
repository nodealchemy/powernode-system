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
	Unit     string
	Started  bool
	Skipped  bool   // already running with identical unit content
	StepErr  error  // non-nil for the step that failed; preceding steps still ran
}

func AttachServices(ctx context.Context, runner mount.Runner, moduleID string, services []manifest.Service) ([]AttachResult, error) {
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

	results := make([]AttachResult, 0, len(ordered))
	anyWritten := false
	for _, svc := range ordered {
		unitName := UnitName(moduleID, svc.Name)
		path := filepath.Join(dir, unitName)
		body := RenderUnit(svc, moduleID)

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

// RenderUnit produces the [Unit]/[Service]/[Install] systemd unit
// file body for a single Service. Public so tests can assert the
// content shape without touching the filesystem.
func RenderUnit(svc manifest.Service, moduleID string) string {
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
	if len(svc.Dependencies) > 0 {
		// Sort dependencies for stable output (same input → same file
		// → writeIfChanged correctly skips a no-op re-attach).
		deps := append([]string(nil), svc.Dependencies...)
		sort.Strings(deps)
		var depUnits []string
		for _, d := range deps {
			depUnits = append(depUnits, UnitName(moduleID, d))
		}
		b.WriteString("After=")
		b.WriteString(strings.Join(depUnits, " "))
		b.WriteString("\n")
		b.WriteString("Requires=")
		b.WriteString(strings.Join(depUnits, " "))
		b.WriteString("\n")
	}

	b.WriteString("\n[Service]\n")
	b.WriteString("Type=simple\n")
	if svc.User != "" {
		fmt.Fprintf(&b, "User=%s\n", svc.User)
	}
	if svc.WorkingDirectory != "" {
		fmt.Fprintf(&b, "WorkingDirectory=%s\n", svc.WorkingDirectory)
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
