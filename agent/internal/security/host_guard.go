package security

import (
	"context"
	"reflect"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
)

// runHost is the ONE place this package runs a command through a Runner
// (TestEveryRunnerCallGoesThroughRunHost holds it to that). nft, semodule and
// apparmor_parser change the machine's own security state, and a command has no
// path for writeguard.Check to inspect, so the production runner is refused as
// a host-global effect while a test binary has the guard enabled. A recorder
// or any other injected runner passes through untouched, and with the guard
// disabled (every production run) this is exactly runner.Run.
func runHost(ctx context.Context, runner mount.Runner, name string, args ...string) error {
	if wrapsExecRunner(reflect.ValueOf(runner), 0) {
		if err := writeguard.CheckHost("run " + name); err != nil {
			return err
		}
	}
	return runner.Run(ctx, name, args...)
}

// wrapsExecRunner reports whether v is the production runner, or a struct (or
// pointer to one) that holds it in a field, so a test double that wraps the real
// runner to intercept one call (a hook runner) is still caught. Depth-bounded.
func wrapsExecRunner(v reflect.Value, depth int) bool {
	if depth > 4 || !v.IsValid() {
		return false
	}
	if v.Type() == execRunnerType {
		return true
	}
	switch v.Kind() {
	case reflect.Interface, reflect.Pointer:
		return !v.IsNil() && wrapsExecRunner(v.Elem(), depth+1)
	case reflect.Struct:
		for i := 0; i < v.NumField(); i++ {
			if wrapsExecRunner(v.Field(i), depth+1) {
				return true
			}
		}
	}
	return false
}

var execRunnerType = reflect.TypeOf(mount.ExecRunner{})
