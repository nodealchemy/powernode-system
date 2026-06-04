// runtimes.go — isolation-runtime provisioning wired into the dockerd reconcile.
//
// When a node is configured to offer an isolation tier (substrate L0) backed by
// an OCI runtime (gvisor=runsc, kata=kata-runtime, firecracker=kata-fc), the
// runtime must be ready AND registered in daemon.json before dockerd starts. The
// Manager calls a RuntimeEnsurer for each RequestedRuntimes entry just before
// WriteDaemonConfig. A CompositeRuntimeEnsurer fans each requested runtime out to
// the handler that owns it (gVisor downloads runsc; Kata validates a microVM
// install), so a node can offer several tiers at once.

package dockerd

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/gvisor"
	"github.com/nodealchemy/powernode-system/agent/internal/kata"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// ErrUnsupportedRuntime is returned by a RuntimeEnsurer for a runtime name it
// doesn't handle, so a CompositeRuntimeEnsurer can try the next handler.
var ErrUnsupportedRuntime = errors.New("unsupported isolation runtime")

// RuntimeEnsurer makes a requested isolation runtime real before the daemon
// starts: it readies the runtime (install or validate) and merges its
// registration into the daemon.json config map. A handler that doesn't own the
// given runtime returns ErrUnsupportedRuntime (wrapped).
type RuntimeEnsurer interface {
	Ensure(ctx context.Context, runtimeName string, daemonConfig map[string]any) error
}

// CompositeRuntimeEnsurer dispatches each runtime to the first sub-ensurer that
// handles it. Order doesn't matter — handlers own disjoint runtime names.
type CompositeRuntimeEnsurer []RuntimeEnsurer

// Ensure tries each handler until one claims the runtime (anything other than
// ErrUnsupportedRuntime — success or a real failure — stops the search).
func (c CompositeRuntimeEnsurer) Ensure(ctx context.Context, runtimeName string, daemonConfig map[string]any) error {
	for _, e := range c {
		err := e.Ensure(ctx, runtimeName, daemonConfig)
		if errors.Is(err, ErrUnsupportedRuntime) {
			continue
		}
		return err // nil (handled OK) or a real provisioning error
	}
	return fmt.Errorf("%w: %q", ErrUnsupportedRuntime, runtimeName)
}

// GvisorRuntimeEnsurer provisions gVisor (runsc): installs the binary if it
// isn't runnable and registers it in daemon.json's runtimes.
type GvisorRuntimeEnsurer struct {
	Runner     mount.Runner
	HTTPClient *http.Client
	BinaryPath string // default gvisor.DefaultBinaryPath
}

// Ensure handles runtimeName "gvisor" (or "runsc"); other names return
// ErrUnsupportedRuntime.
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
		return fmt.Errorf("%w: %q", ErrUnsupportedRuntime, runtimeName)
	}
}

// KataRuntimeEnsurer provisions Kata Containers microVM runtimes (kata-runtime
// and the Firecracker variant kata-fc). It validates the install + KVM (it does
// NOT download the multi-artifact runtime) and registers the variant in
// daemon.json.
type KataRuntimeEnsurer struct {
	Runner       mount.Runner
	BinaryPath   string // default kata.DefaultBinaryPath
	FCConfigPath string // default kata.DefaultFCConfigPath (Firecracker config)
}

// Ensure handles "kata"/"kata-runtime" and "firecracker"/"kata-fc"; other names
// return ErrUnsupportedRuntime.
func (e KataRuntimeEnsurer) Ensure(ctx context.Context, runtimeName string, daemonConfig map[string]any) error {
	variant, ok := kata.VariantFor(runtimeName, e.FCConfigPath)
	if !ok {
		return fmt.Errorf("%w: %q", ErrUnsupportedRuntime, runtimeName)
	}
	if err := kata.EnsureReady(ctx, e.Runner, e.BinaryPath, variant); err != nil {
		return err
	}
	if daemonConfig != nil {
		kata.MergeRuntime(daemonConfig, variant, e.BinaryPath)
	}
	return nil
}
