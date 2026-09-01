package lifecycle

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// TestSystemdHarness_RecoveryProperty is the EXECUTED half of the fix in
// writeDependencyDirectives. Every other test in this package asserts a
// rendered string; a rendered string cannot observe whether systemd
// actually restarts a stranded dependent, which is the entire property
// being claimed. This one boots a real systemd 255 in a container, feeds it
// the units this package ACTUALLY renders, and drives the outage sequence.
//
// It is opt-in (POWERNODE_SYSTEMD_HARNESS=1) because it needs a container
// runtime and ~40s of wall clock; `go test ./...` skips it. Point
// POWERNODE_SYSTEMD_HARNESS_DOCKER at the runtime if `docker` needs a
// wrapper (e.g. "sudo docker").
//
// Run:
//
//	POWERNODE_SYSTEMD_HARNESS=1 POWERNODE_SYSTEMD_HARNESS_DOCKER="sudo docker" \
//	  go test ./internal/lifecycle/ -run SystemdHarness -v -timeout 10m
func TestSystemdHarness_RecoveryProperty(t *testing.T) {
	h := newSystemdHarness(t)

	// The outage shape: a dependency that fails twice (ops-hub's 502 window)
	// then succeeds, and a dependent that hard-requires it.
	h.writeScript("/usr/local/bin/dep.sh", `#!/bin/bash
n=0; [ -f /run/dep.attempts ] && n=$(cat /run/dep.attempts)
n=$((n+1)); echo $n > /run/dep.attempts
[ "$n" -lt 3 ] && exit 1
exit 0
`)
	// The dependency is Type=oneshot via unit_body, faithfully to dev-cell's
	// bootstrap. That is load-bearing, not incidental: with Type=simple the
	// dependency's job SUCCEEDS the instant the process forks, so the
	// dependent starts before the failure is even visible and the strand
	// never happens. Only a job that completes on EXIT can cancel a
	// dependent's job — which is why the outage hit a oneshot. It also puts
	// the recovery directive through renderUnitBodyMode (the unit_body path),
	// while the dependent below goes through the generated path.
	services := []manifest.Service{
		{Name: "bootstrap", UnitBody: `[Unit]
Description=bootstrap (oneshot, as dev-cell ships it)

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/dep.sh
Restart=on-failure
RestartSec=1
`},
		{Name: "mcp-proxy", StartCommand: "/bin/sleep infinity", RestartPolicy: "never",
			DependencyEdges: []manifest.DependencyEdge{
				{Service: "bootstrap", Kind: manifest.DependencyKindStartBefore},
			}},
	}
	depUnit := UnitName("mod-h", "bootstrap")
	dependentUnit := UnitName("mod-h", "mcp-proxy")

	// Render through the real attach path so the harness tests the shipped
	// renderer, not a restatement of it.
	dir := setUnitDir(t)
	if _, err := AttachServicesMode(context.Background(), &mount.RecorderRunner{}, "mod-h", services, RootModeNative); err != nil {
		t.Fatalf("AttachServicesMode: %v", err)
	}
	rendered, err := os.ReadFile(filepath.Join(dir, depUnit))
	if err != nil {
		t.Fatalf("read rendered dependency unit: %v", err)
	}
	if !strings.Contains(string(rendered), "Wants="+dependentUnit) {
		t.Fatalf("precondition: rendered dependency unit carries no recovery Wants=:\n%s", rendered)
	}

	// CONTROL first. Same units with the recovery line stripped — this is the
	// pre-fix renderer. If the harness cannot observe the strand here, a pass
	// in the treatment arm proves nothing.
	control := strings.ReplaceAll(string(rendered), "Wants="+dependentUnit+"\n", "")
	if control == string(rendered) {
		t.Fatalf("control arm did not actually strip the directive")
	}
	h.install(dir, depUnit, dependentUnit, control)
	if got := h.runOutageSequence(t, depUnit, dependentUnit); got != "inactive" {
		t.Errorf("CONTROL (no recovery directive): dependent should stay stranded, got %q", got)
	}

	// TREATMENT: the units as shipped.
	h.install(dir, depUnit, dependentUnit, string(rendered))
	if got := h.runOutageSequence(t, depUnit, dependentUnit); got != "active" {
		t.Errorf("TREATMENT: dependency self-healed but dependent did not recover, got %q", got)
	}

	// The operator-facing cost documented in writeDependencyDirectives: with
	// Wants= (unlike Upholds=) a stop of the dependent STICKS.
	h.systemctl("stop", dependentUnit)
	time.Sleep(4 * time.Second)
	if got := h.isActive(dependentUnit); got != "inactive" {
		t.Errorf("dependent must remain stoppable while the dependency is up, got %q", got)
	}
	if got := h.isActive(depUnit); got != "active" {
		t.Errorf("stopping the dependent must not disturb the dependency, got %q", got)
	}
}

type systemdHarness struct {
	t         *testing.T
	container string
	docker    []string
}

func newSystemdHarness(t *testing.T) *systemdHarness {
	t.Helper()
	if os.Getenv("POWERNODE_SYSTEMD_HARNESS") == "" {
		t.Skip("systemd harness opt-in: set POWERNODE_SYSTEMD_HARNESS=1 (needs a container runtime)")
	}
	dockerCmd := os.Getenv("POWERNODE_SYSTEMD_HARNESS_DOCKER")
	if dockerCmd == "" {
		dockerCmd = "docker"
	}
	// Unique per run: the name is torn down with `rm -f`, so a fixed name
	// would let two concurrent runs (or a human debugging in that container)
	// destroy each other.
	h := &systemdHarness{
		t:         t,
		container: fmt.Sprintf("pn-lifecycle-harness-%d", os.Getpid()),
		docker:    strings.Fields(dockerCmd),
	}

	ctxDir := t.TempDir()
	dockerfile := `FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv dbus \
 && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
`
	if err := os.WriteFile(filepath.Join(ctxDir, "Dockerfile"), []byte(dockerfile), 0o644); err != nil {
		t.Fatalf("write Dockerfile: %v", err)
	}
	h.run("build", "-t", "pn-lifecycle-harness:255", ctxDir)
	h.runAllowFail("rm", "-f", h.container)
	h.run("run", "-d", "--name", h.container, "--privileged", "--cgroupns=private",
		"--tmpfs", "/run", "--tmpfs", "/run/lock", "-v", "/sys/fs/cgroup:/sys/fs/cgroup:rw",
		"pn-lifecycle-harness:255")
	t.Cleanup(func() { h.runAllowFail("rm", "-f", h.container) })

	for i := 0; i < 60; i++ {
		st := strings.TrimSpace(h.execAllowFail("systemctl", "is-system-running"))
		if st == "running" || st == "degraded" {
			return h
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("systemd in container never came up")
	return nil
}

// install places the dependency unit (body supplied, so the caller can run a
// control arm) and the dependent unit as rendered, then daemon-reloads.
func (h *systemdHarness) install(dir, depUnit, dependentUnit, depBody string) {
	h.t.Helper()
	h.writeFile("/etc/systemd/system/"+depUnit, depBody)
	dependentBody, err := os.ReadFile(filepath.Join(dir, dependentUnit))
	if err != nil {
		h.t.Fatalf("read rendered dependent unit: %v", err)
	}
	h.writeFile("/etc/systemd/system/"+dependentUnit, string(dependentBody))
	h.exec("systemctl", "daemon-reload")
}

// runOutageSequence replays 2026-08-31 and reports the dependent's final
// state: start the dependent (which pulls in the dependency), let the
// dependency fail and its dependent's job get cancelled, wait for the
// dependency to self-heal, then observe whether the dependent came back.
func (h *systemdHarness) runOutageSequence(t *testing.T, depUnit, dependentUnit string) string {
	t.Helper()
	h.execAllowFail("rm", "-f", "/run/dep.attempts")
	h.execAllowFail("systemctl", "stop", depUnit, dependentUnit)
	h.execAllowFail("systemctl", "reset-failed", depUnit, dependentUnit)

	h.execAllowFail("systemctl", "start", dependentUnit) // expected to fail
	if got := h.isActive(dependentUnit); got == "active" {
		t.Fatalf("precondition: dependent should NOT be up while the dependency is failing, got %q", got)
	}
	if !h.waitFor(depUnit, "active", 60*time.Second) {
		t.Fatalf("dependency never self-healed (state=%s, attempts=%s)",
			h.isActive(depUnit), strings.TrimSpace(h.execAllowFail("cat", "/run/dep.attempts")))
	}
	h.waitFor(dependentUnit, "active", 15*time.Second)
	return h.isActive(dependentUnit)
}

func (h *systemdHarness) waitFor(unit, want string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if h.isActive(unit) == want {
			return true
		}
		time.Sleep(500 * time.Millisecond)
	}
	return false
}

func (h *systemdHarness) isActive(unit string) string {
	return strings.TrimSpace(h.execAllowFail("systemctl", "is-active", unit))
}

func (h *systemdHarness) systemctl(args ...string) {
	h.exec(append([]string{"systemctl"}, args...)...)
}

func (h *systemdHarness) writeFile(path, content string) {
	h.t.Helper()
	cmd := exec.Command(h.docker[0], append(append([]string{}, h.docker[1:]...),
		"exec", "-i", h.container, "tee", path)...)
	cmd.Stdin = strings.NewReader(content)
	if out, err := cmd.CombinedOutput(); err != nil {
		h.t.Fatalf("write %s: %v\n%s", path, err, out)
	}
}

func (h *systemdHarness) writeScript(path, content string) {
	h.writeFile(path, content)
	h.exec("chmod", "+x", path)
}

func (h *systemdHarness) run(args ...string) string {
	h.t.Helper()
	out, err := h.rawRun(args...)
	if err != nil {
		h.t.Fatalf("%v %v: %v\n%s", h.docker, args, err, out)
	}
	return out
}

func (h *systemdHarness) runAllowFail(args ...string) string {
	out, _ := h.rawRun(args...)
	return out
}

func (h *systemdHarness) exec(args ...string) string {
	return h.run(append([]string{"exec", h.container}, args...)...)
}

func (h *systemdHarness) execAllowFail(args ...string) string {
	return h.runAllowFail(append([]string{"exec", h.container}, args...)...)
}

func (h *systemdHarness) rawRun(args ...string) (string, error) {
	full := append(append([]string{}, h.docker[1:]...), args...)
	out, err := exec.Command(h.docker[0], full...).CombinedOutput()
	return string(out), err
}
