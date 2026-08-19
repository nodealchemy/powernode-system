// Package gvisor provisions the gVisor (runsc) container runtime on a node —
// the first REAL isolation tier of the AI/MCP workload substrate (L0). It:
//
//   - installs the runsc binary for the host arch (downloaded, sha512-verified
//     and written atomically as an executable),
//   - contributes the daemon.json "runtimes" fragment that registers runsc with
//     the Docker daemon (merged by the dockerd applier's ExtraConfig path), and
//   - detects whether gVisor is ready (binary runnable + registered).
//
// Once registered, a container launched with --runtime=runsc (the mapping
// System::IsolationTier resolves for isolation_tier=gvisor) runs inside gVisor's
// userspace kernel sandbox.
package gvisor

import (
	"context"
	"crypto/sha512"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

const (
	// RuntimeName is the Docker/OCI runtime name gVisor registers as.
	RuntimeName = "runsc"
	// DefaultBinaryPath is where runsc is installed.
	DefaultBinaryPath = "/usr/local/bin/runsc"
	// DefaultReleaseBase is gVisor's official release bucket; the arch dir +
	// "runsc"/"runsc.sha512" are appended.
	DefaultReleaseBase = "https://storage.googleapis.com/gvisor/releases/release/latest"
)

// DaemonRuntimesFragment is the daemon.json fragment that registers runsc.
// Merge it into the operator ExtraConfig the dockerd applier renders.
func DaemonRuntimesFragment(binaryPath string) map[string]any {
	return map[string]any{
		"runtimes": map[string]any{
			RuntimeName: map[string]any{"path": resolveBinary(binaryPath)},
		},
	}
}

// MergeRuntimes registers runsc in a daemon.json config map without clobbering
// other runtimes. Returns true if cfg changed.
func MergeRuntimes(cfg map[string]any, binaryPath string) bool {
	path := resolveBinary(binaryPath)
	runtimes, _ := cfg["runtimes"].(map[string]any)
	if runtimes == nil {
		runtimes = map[string]any{}
	}
	if cur, ok := runtimes[RuntimeName].(map[string]any); ok && cur["path"] == path {
		return false
	}
	runtimes[RuntimeName] = map[string]any{"path": path}
	cfg["runtimes"] = runtimes
	return true
}

// Status is the on-node gVisor state.
type Status struct {
	BinaryPresent bool   `json:"binary_present"`
	Version       string `json:"version,omitempty"`
	Registered    bool   `json:"registered"`
}

// Available reports whether gVisor is ready to run containers.
func (s Status) Available() bool { return s.BinaryPresent && s.Registered }

// Detect reports the gVisor state: binary runnable (runsc --version) +
// registered in daemonCfg's runtimes.
func Detect(ctx context.Context, runner mount.Runner, binaryPath string, daemonCfg map[string]any) Status {
	st := Status{}
	if out, err := runner.Output(ctx, resolveBinary(binaryPath), "--version"); err == nil {
		st.BinaryPresent = true
		st.Version = firstLine(string(out))
	}
	if runtimes, ok := daemonCfg["runtimes"].(map[string]any); ok {
		_, st.Registered = runtimes[RuntimeName]
	}
	return st
}

// InstallOptions configures the runsc download + install.
type InstallOptions struct {
	BinaryPath  string // default DefaultBinaryPath
	ReleaseBase string // default DefaultReleaseBase
	Arch        string // default runtime.GOARCH (amd64->x86_64, arm64->aarch64)
	HTTPClient  *http.Client
}

// EnsureInstalled installs runsc only if it isn't already runnable. Returns
// whether an install happened.
func EnsureInstalled(ctx context.Context, runner mount.Runner, opts InstallOptions) (bool, error) {
	if _, err := runner.Output(ctx, resolveBinary(opts.BinaryPath), "--version"); err == nil {
		return false, nil
	}
	if err := Install(ctx, opts); err != nil {
		return false, err
	}
	return true, nil
}

// Install downloads runsc + runsc.sha512 for the host arch, verifies the
// checksum, and writes the executable atomically.
func Install(ctx context.Context, opts InstallOptions) error {
	client := opts.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Minute}
	}
	base := strings.TrimRight(orDefault(opts.ReleaseBase, DefaultReleaseBase), "/") + "/" + archToken(opts.Arch)

	bin, err := fetch(ctx, client, base+"/"+RuntimeName)
	if err != nil {
		return fmt.Errorf("download runsc: %w", err)
	}
	sumRaw, err := fetch(ctx, client, base+"/"+RuntimeName+".sha512")
	if err != nil {
		return fmt.Errorf("download runsc.sha512: %w", err)
	}
	if err := verifySHA512(bin, sumRaw); err != nil {
		return err
	}
	return writeExecutable(resolveBinary(opts.BinaryPath), bin)
}

func fetch(ctx context.Context, client *http.Client, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d for %s", resp.StatusCode, url)
	}
	return io.ReadAll(resp.Body)
}

func verifySHA512(data, sumFile []byte) error {
	want := strings.TrimSpace(string(sumFile))
	if i := strings.IndexAny(want, " \t"); i > 0 { // "sha512sum" format: "<hex>  runsc"
		want = want[:i]
	}
	sum := sha512.Sum512(data)
	got := hex.EncodeToString(sum[:])
	if !strings.EqualFold(strings.TrimSpace(want), got) {
		return fmt.Errorf("runsc sha512 mismatch: want %s got %s", want, got)
	}
	return nil
}

func writeExecutable(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".runsc-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o755); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

// archToken maps Go's GOARCH to gVisor's release arch directory naming.
func archToken(goarch string) string {
	if goarch == "" {
		goarch = runtime.GOARCH
	}
	switch goarch {
	case "amd64", "x86_64":
		return "x86_64"
	case "arm64", "aarch64":
		return "aarch64"
	default:
		return goarch
	}
}

func resolveBinary(p string) string {
	if strings.TrimSpace(p) == "" {
		return DefaultBinaryPath
	}
	return p
}

func orDefault(v, d string) string {
	if strings.TrimSpace(v) == "" {
		return d
	}
	return v
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return strings.TrimSpace(s)
}
