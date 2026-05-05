package dockerd

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// recordingExec is the test stub for ShellApplier.Exec. Records every
// invocation so assertions can verify both the command shape and the
// call count. Returns canned stdout/error per command name.
type recordingExec struct {
	calls []execCall

	// Per-command canned responses. Key is the literal first-arg
	// command name (e.g. "systemctl", "docker"). Tests can set
	// per-test responses without recompiling.
	stdout map[string]string
	err    map[string]error
}

type execCall struct {
	name string
	args []string
}

func (r *recordingExec) run(_ context.Context, name string, args ...string) ([]byte, error) {
	r.calls = append(r.calls, execCall{name: name, args: append([]string(nil), args...)})
	out := r.stdout[name]
	return []byte(out), r.err[name]
}

func newRecordingExec() *recordingExec {
	return &recordingExec{stdout: map[string]string{}, err: map[string]error{}}
}

// applierWithTmpPaths returns a fresh applier rooted in a tmpdir, so
// the cert + config writes don't pollute /etc/docker. The exec stub
// is wired so no real systemctl is invoked.
func applierWithTmpPaths(t *testing.T) (*ShellApplier, *recordingExec, string) {
	t.Helper()
	dir := t.TempDir()
	exec := newRecordingExec()
	a := &ShellApplier{
		Paths: DaemonPaths{
			CAFile:     filepath.Join(dir, "ca.pem"),
			CertFile:   filepath.Join(dir, "server-cert.pem"),
			KeyFile:    filepath.Join(dir, "server-key.pem"),
			ConfigFile: filepath.Join(dir, "daemon.json"),
		},
		Unit: "docker.service",
		Exec: exec.run,
	}
	return a, exec, dir
}

// ──────────────────────────────────────────────────────────────────
// Cert IO tests
// ──────────────────────────────────────────────────────────────────

func TestShellApplier_HasCert_FalseWhenAbsent(t *testing.T) {
	a, _, _ := applierWithTmpPaths(t)
	got, err := a.HasCert(context.Background())
	if err != nil {
		t.Fatalf("HasCert: %v", err)
	}
	if got {
		t.Fatal("expected HasCert=false on empty tmpdir")
	}
}

func TestShellApplier_HasCert_TrueAfterWrite(t *testing.T) {
	a, _, _ := applierWithTmpPaths(t)
	if err := a.WriteCert(context.Background(), CertMaterial{
		CAChainPEM:    "ca",
		ServerCertPEM: "cert",
		ServerKeyPEM:  "key",
	}); err != nil {
		t.Fatalf("WriteCert: %v", err)
	}
	got, err := a.HasCert(context.Background())
	if err != nil {
		t.Fatalf("HasCert: %v", err)
	}
	if !got {
		t.Fatal("expected HasCert=true after WriteCert")
	}
}

func TestShellApplier_WriteCert_KeyHasRestrictedPerms(t *testing.T) {
	a, _, _ := applierWithTmpPaths(t)
	if err := a.WriteCert(context.Background(), CertMaterial{
		CAChainPEM: "ca", ServerCertPEM: "cert", ServerKeyPEM: "key",
	}); err != nil {
		t.Fatalf("WriteCert: %v", err)
	}

	st, err := os.Stat(a.Paths.KeyFile)
	if err != nil {
		t.Fatalf("stat key: %v", err)
	}
	// Mask off the file type bits — only check the perm low bits.
	if got := st.Mode().Perm(); got != 0o600 {
		t.Fatalf("expected key perms 0600, got %#o", got)
	}

	st, err = os.Stat(a.Paths.CertFile)
	if err != nil {
		t.Fatalf("stat cert: %v", err)
	}
	if got := st.Mode().Perm(); got != 0o644 {
		t.Fatalf("expected cert perms 0644, got %#o", got)
	}
}

func TestShellApplier_WriteCert_RejectsEmptyPEM(t *testing.T) {
	a, _, _ := applierWithTmpPaths(t)
	err := a.WriteCert(context.Background(), CertMaterial{
		CAChainPEM: "ca", ServerCertPEM: "", ServerKeyPEM: "key",
	})
	if err == nil {
		t.Fatal("expected error for empty server cert")
	}
}

func TestShellApplier_RemoveCert_TolerantOfMissing(t *testing.T) {
	a, _, _ := applierWithTmpPaths(t)
	// No files written yet — RemoveCert should still succeed.
	if err := a.RemoveCert(context.Background()); err != nil {
		t.Fatalf("expected RemoveCert to tolerate missing files, got %v", err)
	}
}

func TestShellApplier_RemoveCert_DeletesAll(t *testing.T) {
	a, _, _ := applierWithTmpPaths(t)
	if err := a.WriteCert(context.Background(), CertMaterial{
		CAChainPEM: "ca", ServerCertPEM: "cert", ServerKeyPEM: "key",
	}); err != nil {
		t.Fatalf("seed WriteCert: %v", err)
	}
	if err := a.RemoveCert(context.Background()); err != nil {
		t.Fatalf("RemoveCert: %v", err)
	}
	for _, p := range []string{a.Paths.CAFile, a.Paths.CertFile, a.Paths.KeyFile} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("expected %s removed, got err=%v", p, err)
		}
	}
}

// ──────────────────────────────────────────────────────────────────
// daemon.json render tests
// ──────────────────────────────────────────────────────────────────

func TestShellApplier_WriteDaemonConfig_RendersValidJSON(t *testing.T) {
	a, _, _ := applierWithTmpPaths(t)
	cfg := DaemonConfig{
		ListenAddress: "tcp://[fd00::1]:2376",
		TLSCAPath:     "/etc/docker/ca.pem",
		TLSCertPath:   "/etc/docker/server-cert.pem",
		TLSKeyPath:    "/etc/docker/server-key.pem",
	}
	if err := a.WriteDaemonConfig(context.Background(), cfg); err != nil {
		t.Fatalf("WriteDaemonConfig: %v", err)
	}
	body, err := os.ReadFile(a.Paths.ConfigFile)
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	for _, want := range []string{
		`"hosts"`, `"fd://"`, `"tcp://[fd00::1]:2376"`,
		`"tls": true`, `"tlsverify": true`,
		`"tlscacert": "/etc/docker/ca.pem"`,
		`"tlskey": "/etc/docker/server-key.pem"`,
	} {
		if !strings.Contains(string(body), want) {
			t.Fatalf("daemon.json missing %q\nbody:\n%s", want, body)
		}
	}
}

// Slice 10 — operator-supplied ExtraConfig (registry-mirrors,
// log-driver, log-opts) is merged INTO the rendered daemon.json
// alongside the platform-managed TLS+listen base.
func TestShellApplier_WriteDaemonConfig_MergesOperatorOverrides(t *testing.T) {
	a, _, _ := applierWithTmpPaths(t)
	cfg := DaemonConfig{
		ListenAddress: "tcp://[fd00::1]:2376",
		TLSCAPath:     "/etc/docker/ca.pem",
		TLSCertPath:   "/etc/docker/server-cert.pem",
		TLSKeyPath:    "/etc/docker/server-key.pem",
		ExtraConfig: map[string]any{
			"registry-mirrors": []any{"https://mirror.gcr.io"},
			"log-driver":       "journald",
			"log-opts": map[string]any{
				"max-size": "10m",
				"max-file": "3",
			},
			"debug": true,
		},
	}
	if err := a.WriteDaemonConfig(context.Background(), cfg); err != nil {
		t.Fatalf("WriteDaemonConfig: %v", err)
	}
	body, err := os.ReadFile(a.Paths.ConfigFile)
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	for _, want := range []string{
		`"registry-mirrors"`, `"https://mirror.gcr.io"`,
		`"log-driver": "journald"`,
		`"log-opts"`, `"max-size": "10m"`,
		`"debug": true`,
		// Platform-managed keys still present + correct
		`"tls": true`, `"tlsverify": true`,
		`"hosts"`, `"tcp://[fd00::1]:2376"`,
	} {
		if !strings.Contains(string(body), want) {
			t.Fatalf("merged daemon.json missing %q\nbody:\n%s", want, body)
		}
	}
}

// Slice 10 — operator overrides for security-managed keys
// (tls/tlsverify/tlscacert/tlscert/tlskey/hosts) are silently dropped.
// The platform's resolver also strips them; this is defense in depth.
func TestShellApplier_WriteDaemonConfig_StripsBlockedKeys(t *testing.T) {
	a, _, _ := applierWithTmpPaths(t)
	cfg := DaemonConfig{
		ListenAddress: "tcp://[fd00::1]:2376",
		TLSCAPath:     "/etc/docker/ca.pem",
		TLSCertPath:   "/etc/docker/server-cert.pem",
		TLSKeyPath:    "/etc/docker/server-key.pem",
		ExtraConfig: map[string]any{
			// Operator attempts to disable TLS — agent must override.
			"tls":       false,
			"tlsverify": false,
			"tlscacert": "/tmp/attacker-ca.pem",
			"tlskey":    "/tmp/attacker-key.pem",
			"hosts":     []any{"tcp://0.0.0.0:2375"},
			// Legitimate operator key — must still apply.
			"log-driver": "json-file",
		},
	}
	if err := a.WriteDaemonConfig(context.Background(), cfg); err != nil {
		t.Fatalf("WriteDaemonConfig: %v", err)
	}
	body, err := os.ReadFile(a.Paths.ConfigFile)
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	bodyStr := string(body)
	// Platform values must win.
	for _, want := range []string{
		`"tls": true`,
		`"tlsverify": true`,
		`"tlscacert": "/etc/docker/ca.pem"`,
		`"tlskey": "/etc/docker/server-key.pem"`,
		`"tcp://[fd00::1]:2376"`,
		`"log-driver": "json-file"`,
	} {
		if !strings.Contains(bodyStr, want) {
			t.Fatalf("daemon.json missing %q after blocked-key strip\nbody:\n%s", want, bodyStr)
		}
	}
	// Attacker-supplied values must NOT appear.
	for _, forbidden := range []string{
		`/tmp/attacker-ca.pem`,
		`/tmp/attacker-key.pem`,
		`tcp://0.0.0.0:2375`,
		`"tls": false`,
	} {
		if strings.Contains(bodyStr, forbidden) {
			t.Fatalf("daemon.json contains forbidden value %q\nbody:\n%s", forbidden, bodyStr)
		}
	}
}

func TestShellApplier_WriteDaemonConfig_NoOpOnMatch(t *testing.T) {
	a, _, _ := applierWithTmpPaths(t)
	cfg := DaemonConfig{ListenAddress: "tcp://[fd00::1]:2376"}

	if err := a.WriteDaemonConfig(context.Background(), cfg); err != nil {
		t.Fatalf("first write: %v", err)
	}
	st1, _ := os.Stat(a.Paths.ConfigFile)

	// Second write with same cfg — file mtime should be unchanged
	// because the applier no-ops when content matches.
	if err := a.WriteDaemonConfig(context.Background(), cfg); err != nil {
		t.Fatalf("second write: %v", err)
	}
	st2, _ := os.Stat(a.Paths.ConfigFile)

	if !st1.ModTime().Equal(st2.ModTime()) {
		t.Fatalf("expected no-op rewrite, mtime changed from %v to %v", st1.ModTime(), st2.ModTime())
	}
}

// ──────────────────────────────────────────────────────────────────
// systemctl tests (with stub exec)
// ──────────────────────────────────────────────────────────────────

func TestShellApplier_IsDaemonRunning_ParsesActive(t *testing.T) {
	a, exec, _ := applierWithTmpPaths(t)
	exec.stdout["systemctl"] = "active\n"

	got, err := a.IsDaemonRunning(context.Background())
	if err != nil {
		t.Fatalf("IsDaemonRunning: %v", err)
	}
	if !got {
		t.Fatal("expected true for active output")
	}
	if len(exec.calls) != 1 || exec.calls[0].name != "systemctl" {
		t.Fatalf("expected systemctl call, got %+v", exec.calls)
	}
	if exec.calls[0].args[0] != "is-active" || exec.calls[0].args[1] != "docker.service" {
		t.Fatalf("expected `systemctl is-active docker.service`, got %+v", exec.calls[0].args)
	}
}

func TestShellApplier_IsDaemonRunning_FalseForOtherStates(t *testing.T) {
	a, exec, _ := applierWithTmpPaths(t)
	for _, state := range []string{"inactive", "failed", "activating", "deactivating"} {
		exec.stdout["systemctl"] = state + "\n"
		got, err := a.IsDaemonRunning(context.Background())
		if err != nil {
			t.Fatalf("IsDaemonRunning(%q): %v", state, err)
		}
		if got {
			t.Fatalf("expected false for state %q", state)
		}
	}
}

func TestShellApplier_StartDaemon_PropagatesError(t *testing.T) {
	a, exec, _ := applierWithTmpPaths(t)
	exec.err["systemctl"] = errors.New("Unit docker.service not found")

	if err := a.StartDaemon(context.Background()); err == nil {
		t.Fatal("expected error from StartDaemon")
	}
}

func TestShellApplier_StartDaemon_RunsCorrectCmd(t *testing.T) {
	a, exec, _ := applierWithTmpPaths(t)
	if err := a.StartDaemon(context.Background()); err != nil {
		t.Fatalf("StartDaemon: %v", err)
	}
	if len(exec.calls) != 1 {
		t.Fatalf("expected 1 exec call, got %d", len(exec.calls))
	}
	args := exec.calls[0].args
	if args[0] != "start" || args[1] != "docker.service" {
		t.Fatalf("expected `systemctl start docker.service`, got %+v", args)
	}
}

func TestShellApplier_StopDaemon_RunsCorrectCmd(t *testing.T) {
	a, exec, _ := applierWithTmpPaths(t)
	if err := a.StopDaemon(context.Background()); err != nil {
		t.Fatalf("StopDaemon: %v", err)
	}
	args := exec.calls[0].args
	if args[0] != "stop" || args[1] != "docker.service" {
		t.Fatalf("expected `systemctl stop docker.service`, got %+v", args)
	}
}

func TestShellApplier_DaemonVersion_TrimsAndReturns(t *testing.T) {
	a, exec, _ := applierWithTmpPaths(t)
	exec.stdout["docker"] = "25.0.3\n"

	got, err := a.DaemonVersion(context.Background())
	if err != nil {
		t.Fatalf("DaemonVersion: %v", err)
	}
	if got != "25.0.3" {
		t.Fatalf("expected 25.0.3, got %q", got)
	}
}

func TestShellApplier_DaemonVersion_EmptyOnError(t *testing.T) {
	a, exec, _ := applierWithTmpPaths(t)
	exec.err["docker"] = errors.New("Cannot connect to the Docker daemon")

	got, err := a.DaemonVersion(context.Background())
	if err != nil {
		t.Fatalf("expected nil error on docker daemon failure, got %v", err)
	}
	if got != "" {
		t.Fatalf("expected empty string on error, got %q", got)
	}
}

// Custom systemd unit name path (used when running multiple Docker
// daemons via instance-style units, e.g. docker@buildx.service).
func TestShellApplier_CustomUnitName(t *testing.T) {
	a, exec, _ := applierWithTmpPaths(t)
	a.Unit = "docker@workload.service"

	_ = a.StartDaemon(context.Background())
	if exec.calls[0].args[1] != "docker@workload.service" {
		t.Fatalf("expected custom unit name propagated, got %q", exec.calls[0].args[1])
	}
}
