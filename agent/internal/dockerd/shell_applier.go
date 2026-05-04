package dockerd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ShellApplier is the production DaemonApplier. Wraps os/exec for the
// systemctl + docker calls and `os` for the cert/config file IO.
//
// Constructor (NewShellApplier) is intentionally minimal — pass a
// DaemonPaths struct (use DefaultPaths in production) and you get a
// usable applier. The Exec field is exposed so tests can inject a
// fake exec without standing up a real systemd; production code can
// leave it nil to get the os/exec default.
//
// Idempotency contract:
//   HasCert       — true iff all 3 PEM files exist + are non-empty
//   WriteCert     — atomic per-file write (.tmp + rename); replaces
//                   prior material on rotation
//   RemoveCert    — best-effort delete; tolerates already-absent
//   WriteDaemonConfig — atomic write; no-op if rendered bytes
//                   match the on-disk file
//   IsDaemonRunning — `systemctl is-active <unit>` parsed strictly
//                   (must equal "active\n"); any other output → false
//   StartDaemon / StopDaemon — `systemctl start/stop <unit>`;
//                   tolerates "already started/stopped" exit codes
//   DaemonVersion — `docker version --format '{{.Server.Version}}'`;
//                   returns "" + nil when the daemon isn't running
type ShellApplier struct {
	// Paths is the on-disk layout. Required.
	Paths DaemonPaths

	// Unit is the systemd unit name. Defaults to "docker.service".
	Unit string

	// Exec is the injectable command runner. Signature matches
	// os/exec.CommandContext + .Output() → ([]byte, error). Tests
	// override with a recording stub. Production leaves nil to get
	// the default os/exec impl.
	Exec func(ctx context.Context, name string, args ...string) ([]byte, error)
}

// NewShellApplier returns an applier wired to DefaultPaths +
// "docker.service". Use the struct directly to override.
func NewShellApplier() *ShellApplier {
	return &ShellApplier{Paths: DefaultPaths, Unit: "docker.service"}
}

func (s *ShellApplier) unit() string {
	if s.Unit == "" {
		return "docker.service"
	}
	return s.Unit
}

func (s *ShellApplier) execCmd(ctx context.Context, name string, args ...string) ([]byte, error) {
	if s.Exec != nil {
		return s.Exec(ctx, name, args...)
	}
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.Output()
	if err != nil {
		// Surface stderr in the error so operators see the real reason
		// (e.g. "Failed to start docker.service: Unit not found").
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return out, fmt.Errorf("%s %s: %w (stderr: %s)", name, strings.Join(args, " "), err, strings.TrimSpace(string(ee.Stderr)))
		}
		return out, fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}
	return out, nil
}

// ──────────────────────────────────────────────────────────────────
// Cert IO
// ──────────────────────────────────────────────────────────────────

func (s *ShellApplier) HasCert(_ context.Context) (bool, error) {
	for _, p := range []string{s.Paths.CAFile, s.Paths.CertFile, s.Paths.KeyFile} {
		st, err := os.Stat(p)
		if err != nil {
			if os.IsNotExist(err) {
				return false, nil
			}
			return false, fmt.Errorf("stat %s: %w", p, err)
		}
		if st.Size() == 0 {
			return false, nil
		}
	}
	return true, nil
}

// WriteCert persists each PEM atomically — write to .tmp + rename.
// Permissions: key 0600, cert + ca 0644 (cert is public; key never).
// Parent directories are created if absent (handles fresh installs
// where /etc/docker doesn't exist yet because the package wasn't
// installed when the agent first booted).
func (s *ShellApplier) WriteCert(_ context.Context, m CertMaterial) error {
	files := []struct {
		path string
		data string
		mode os.FileMode
	}{
		{s.Paths.CAFile, m.CAChainPEM, 0o644},
		{s.Paths.CertFile, m.ServerCertPEM, 0o644},
		{s.Paths.KeyFile, m.ServerKeyPEM, 0o600},
	}
	for _, f := range files {
		if f.data == "" {
			return fmt.Errorf("WriteCert: empty PEM for %s", f.path)
		}
		if err := os.MkdirAll(filepath.Dir(f.path), 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", filepath.Dir(f.path), err)
		}
		if err := atomicWrite(f.path, []byte(f.data), f.mode); err != nil {
			return fmt.Errorf("write %s: %w", f.path, err)
		}
	}
	return nil
}

func (s *ShellApplier) RemoveCert(_ context.Context) error {
	for _, p := range []string{s.Paths.CAFile, s.Paths.CertFile, s.Paths.KeyFile} {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("remove %s: %w", p, err)
		}
	}
	return nil
}

// ──────────────────────────────────────────────────────────────────
// daemon.json render
// ──────────────────────────────────────────────────────────────────

// daemonConfigJSON is the on-disk structure. Only the keys the
// reconciler manages are listed — operator-supplied keys (log-driver,
// registry-mirrors, etc.) come from the docker-engine-config
// config-variety NodeModule via a layered render that's out of scope
// for v1 (and currently the agent doesn't have a way to receive
// per-host config either; that's the next step).
//
// Reference: https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file
type daemonConfigJSON struct {
	Hosts        []string `json:"hosts"`
	TLS          bool     `json:"tls"`
	TLSVerify    bool     `json:"tlsverify"`
	TLSCACert    string   `json:"tlscacert"`
	TLSCert      string   `json:"tlscert"`
	TLSKey       string   `json:"tlskey"`
}

func (s *ShellApplier) WriteDaemonConfig(_ context.Context, cfg DaemonConfig) error {
	doc := daemonConfigJSON{
		// "fd://" keeps the systemd-managed unix socket so docker CLI
		// on the node still works for operator debugging. The TCP
		// listen on the SDWAN overlay is added alongside, not in
		// place of.
		Hosts:     []string{"fd://", cfg.ListenAddress},
		TLS:       true,
		TLSVerify: true,
		TLSCACert: cfg.TLSCAPath,
		TLSCert:   cfg.TLSCertPath,
		TLSKey:    cfg.TLSKeyPath,
	}
	rendered, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal daemon.json: %w", err)
	}
	rendered = append(rendered, '\n')

	// No-op if on-disk file already matches — avoids triggering an
	// inotify watcher / reload daemon for nothing.
	if existing, err := os.ReadFile(s.Paths.ConfigFile); err == nil {
		if stringsEqual(existing, rendered) {
			return nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(s.Paths.ConfigFile), 0o755); err != nil {
		return err
	}
	return atomicWrite(s.Paths.ConfigFile, rendered, 0o644)
}

// ──────────────────────────────────────────────────────────────────
// systemctl + docker version
// ──────────────────────────────────────────────────────────────────

// IsDaemonRunning returns true iff `systemctl is-active <unit>`
// returns exactly "active\n". `systemctl is-active` exits non-zero
// when the unit is anything other than active, but stdout still
// carries the state ("inactive", "failed", etc.) which we ignore.
func (s *ShellApplier) IsDaemonRunning(ctx context.Context) (bool, error) {
	out, _ := s.execCmd(ctx, "systemctl", "is-active", s.unit())
	return strings.TrimSpace(string(out)) == "active", nil
}

func (s *ShellApplier) StartDaemon(ctx context.Context) error {
	_, err := s.execCmd(ctx, "systemctl", "start", s.unit())
	if err != nil {
		// `systemctl start` returns 0 even when the unit is already
		// active, so any error here is real (missing unit, masked
		// unit, dependency failure).
		return err
	}
	return nil
}

func (s *ShellApplier) StopDaemon(ctx context.Context) error {
	_, err := s.execCmd(ctx, "systemctl", "stop", s.unit())
	if err != nil {
		return err
	}
	return nil
}

func (s *ShellApplier) DaemonVersion(ctx context.Context) (string, error) {
	out, err := s.execCmd(ctx, "docker", "version", "--format", "{{.Server.Version}}")
	if err != nil {
		// Daemon not running, docker CLI not installed, or socket
		// permission error. Treat all as "version unknown" — the
		// reconciler reports empty string to the platform.
		return "", nil
	}
	return strings.TrimSpace(string(out)), nil
}

// ──────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────

// atomicWrite writes data to a sibling .tmp file and renames over
// the target. On Linux this is atomic — readers either see the old
// contents or the new, never a half-written file. Important for the
// TLS key + cert files since dockerd watches them.
func atomicWrite(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".dockerd-applier-*")
	if err != nil {
		return err
	}
	cleanup := func() { _ = os.Remove(tmp.Name()) }

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// stringsEqual is a byte-slice equality check that's allocation-free
// vs. converting to string. Used by WriteDaemonConfig to skip the
// rewrite when content matches.
func stringsEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
