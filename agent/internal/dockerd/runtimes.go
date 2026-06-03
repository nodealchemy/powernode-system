// runtimes.go — isolation-runtime provisioning wired into the dockerd reconcile.
//
// When a node is configured to offer an isolation tier (substrate L0) backed by
// an OCI runtime (e.g. gvisor=runsc), the runtime's binary must exist AND be
// registered in daemon.json before dockerd starts — otherwise the daemon
// refuses to start with a missing-runtime error. The Manager calls a
// RuntimeEnsurer for each RequestedRuntimes entry just before WriteDaemonConfig,
// so the runtime is installed + merged into the rendered config in one pass.

package dockerd

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/gvisor"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// RuntimeEnsurer makes a requested isolation runtime real before the daemon
// starts: it installs the runtime binary (if missing) and merges its
// registration into the daemon.json config map.
type RuntimeEnsurer interface {
	Ensure(ctx context.Context, runtimeName string, daemonConfig map[string]any) error
}

// GvisorRuntimeEnsurer provisions gVisor (runsc): installs the binary if it
// isn't runnable and registers it in daemon.json's runtimes.
type GvisorRuntimeEnsurer struct {
	Runner     mount.Runner
	HTTPClient *http.Client
	BinaryPath string // default gvisor.DefaultBinaryPath
}

// Ensure handles runtimeName "gvisor" (or "runsc"); other names are an error
// (a different ensurer handles them).
func (e GvisorRuntimeEnsurer) Ensure(ctx context.Context, runtimeName string, daemonConfig map[string]any) error {
	switch strings.ToLower(strings.TrimSpace(runtimeName)) {
	case "gvisor", gvisor.RuntimeName:
		if _, err := gvisor.EnsureInstalled(ctx, e.Runner, gvisor.InstallOptions{
			BinaryPath: e.BinaryPath,
			HTTPClient: e.HTTPClient,
		}); err != nil {
			return fmt.Errorf("ensure gvisor: %w", err)
		}
		if daemonConfig != nil {
			gvisor.MergeRuntimes(daemonConfig, e.BinaryPath)
		}
		return nil
	default:
		return fmt.Errorf("unsupported isolation runtime %q", runtimeName)
	}
}
